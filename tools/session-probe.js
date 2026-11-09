#!/usr/bin/env node
// Read what a DSH session record actually says: which role it ran, which model it
// ran on, and how big its work packet was.
//
//   node tools/session-probe.js <session-id-prefix | session-dir | bucket-name>
//   node tools/session-probe.js --all <bucket-name>
//   node tools/session-probe.js <prefix> --json
//
// Why this exists: a configuration file says what *should* run; only the session
// record says what did. Answering "did the model pin reach the wire?" by hand
// means splitting a concatenated-frame zstd file, which is easy to get wrong and
// was rewritten three times before it landed here.
//
// Record layout: ~/.dsh/sessions/<bucket>/<session>/session.v4.jsonl.zstd, one
// zstd frame per appended batch, decompressed frame by frame below.

const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");

const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const ROLE_HEAD = /ROLE: (explorer|researcher|worker|tester|reviewer) \(/;

function decompressFrames(buffer) {
  const cuts = [];
  let at = buffer.indexOf(ZSTD_MAGIC, 0);
  while (at !== -1) {
    cuts.push(at);
    at = buffer.indexOf(ZSTD_MAGIC, at + 4);
  }
  cuts.push(buffer.length);
  const parts = [];
  let badFrames = 0;
  for (let i = 0; i < cuts.length - 1; i += 1) {
    try {
      parts.push(zlib.zstdDecompressSync(buffer.subarray(cuts[i], cuts[i + 1])));
    } catch {
      // A magic sequence inside compressed data: those bytes are already inside
      // the neighbouring frame, so skipping both is safer than guessing.
      badFrames += 1;
    }
  }
  return { text: Buffer.concat(parts).toString("utf8"), badFrames };
}

function probe(sessionDir) {
  const file = path.join(sessionDir, "session.v4.jsonl.zstd");
  if (!fs.existsSync(file)) return null;
  const { text, badFrames } = decompressFrames(fs.readFileSync(file));

  const models = new Map();
  const providers = new Map();
  let role = null;
  let packetChars = 0;
  let records = 0;

  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    records += 1;
    const flat = JSON.stringify(record);
    for (const hit of flat.match(/"model"\s*:\s*"([^"]+)"/g) || []) {
      const value = hit.split('"')[3];
      models.set(value, (models.get(value) || 0) + 1);
    }
    for (const hit of flat.match(/"provider"\s*:\s*"([^"]+)"/g) || []) {
      const value = hit.split('"')[3];
      providers.set(value, (providers.get(value) || 0) + 1);
    }
    // The work packet is the spawned session's first user message, so only the
    // opening records can name the role. Without this bound, a parent session that
    // quotes a packet (or the pipeline script) reads as a node of its own.
    if (!role && records <= 10) {
      // The packet opens with the role header and carries the blocks the pipeline
      // builds; a file the agent merely read lacks that shape.
      const head = flat.match(ROLE_HEAD);
      if (head && flat.includes("OBJECTIVE:") && flat.includes("REQUIREMENTS:")) {
        role = head[1];
        packetChars = flat.length;
      }
    }
  }

  return {
    session: path.basename(sessionDir),
    role: role || "(root or non-pipeline session)",
    models: Array.from(models.keys()),
    providers: Array.from(providers.keys()),
    records,
    packetChars,
    badFrames
  };
}

function findSessions(needle) {
  const root = path.join(os.homedir(), ".dsh", "sessions");
  if (!fs.existsSync(root)) return [];

  const direct = path.isAbsolute(needle) ? needle : path.join(root, needle);
  if (fs.existsSync(path.join(direct, "session.v4.jsonl.zstd"))) return [direct];

  const out = [];
  for (const bucket of fs.readdirSync(root)) {
    const bucketDir = path.join(root, bucket);
    if (!fs.statSync(bucketDir).isDirectory()) continue;
    for (const name of fs.readdirSync(bucketDir)) {
      const dir = path.join(bucketDir, name);
      if (!fs.existsSync(path.join(dir, "session.v4.jsonl.zstd"))) continue;
      const isBucket = needle === bucket;
      // Session directories are usually named after their id, but a resumed one
      // carries a "session-" prefix, so a plain prefix test misses it.
      if (isBucket || name.startsWith(needle) || name.includes(needle)) out.push(dir);
    }
  }
  return out;
}

const argv = process.argv.slice(2).filter((a) => a !== "--json");
const asJson = process.argv.includes("--json");
const needle = argv[argv.length - 1] || "";

if (!needle) {
  console.error("usage: node tools/session-probe.js <session-id-prefix | session-dir | bucket-name> [--json]");
  process.exit(2);
}

const dirs = findSessions(needle);
if (dirs.length === 0) {
  console.error("no session matched " + JSON.stringify(needle) + " under ~/.dsh/sessions");
  process.exit(1);
}

const rows = dirs.map(probe).filter(Boolean);
if (asJson) {
  console.log(JSON.stringify(rows, null, 2));
  process.exit(0);
}

for (const row of rows) {
  console.log(
    row.session.slice(0, 8).padEnd(9),
    "| role:", row.role.padEnd(30),
    "| model:", (row.models.join(",") || "-").padEnd(20),
    "| provider:", (row.providers.join(",") || "-").padEnd(24),
    "| records:", String(row.records).padStart(4),
    "| packet:", String(row.packetChars).padStart(6)
  );
}
