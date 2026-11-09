#!/usr/bin/env node
// Fails when the check counts written in README.md / AGENTS.md do not match a real
// run. Those numbers drifted twice in one afternoon because nothing compared them.
//
//   node tests/check-doc-counts.js        (reads tests/.last-run.json from run-all.ps1)
//
// With no state file (CI), it runs the profiles suite itself to get a real number.
// The two install counts are only checked when run-all.ps1 recorded them.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const STATE = path.join(__dirname, ".last-run.json");

let failures = 0;
let checks = 0;
let skipped = 0;

function ok(condition, message) {
  checks += 1;
  if (!condition) {
    failures += 1;
    console.log("  FAIL  " + message);
  }
}

function readCounts() {
  if (fs.existsSync(STATE)) {
    // Windows PowerShell's Out-File utf8 writes a BOM; strip it before parsing.
    const raw = fs.readFileSync(STATE, "utf8").replace(/^\uFEFF/, "");
    const data = JSON.parse(raw);
    return {
      source: "tests/.last-run.json (" + data.generatedAt + ")",
      profiles: data.profiles || null,
      installPs: data.installPs || null,
      installSh: data.installSh || null
    };
  }
  const run = spawnSync(process.execPath, [path.join(__dirname, "test_profiles.js")], {
    cwd: ROOT,
    encoding: "utf8"
  });
  if (run.error || typeof run.stdout !== "string") {
    console.log("FAIL - no tests/.last-run.json, and the profile suite could not be run: " +
      (run.error ? run.error.message : "no output"));
    console.log("       run tests/run-all.ps1 instead of this file directly.");
    process.exit(1);
  }
  const hit = run.stdout.match(/(\d+)\/(\d+) checks passed/);
  if (!hit) {
    console.log("FAIL - could not read a check count from tests/test_profiles.js");
    process.exit(1);
  }
  return {
    source: "a fresh run of tests/test_profiles.js",
    profiles: { Passed: Number(hit[1]), Total: Number(hit[2]), Exit: run.status },
    installPs: null,
    installSh: null
  };
}

const counts = readCounts();
console.log("== documentation check counts");
console.log("   expected from " + counts.source);

const claims = [
  { file: "README.md", kind: "profiles", label: "README layout row: profiles", pattern: /tests\/test_profiles\.js\s+(\d+) checks/ },
  { file: "README.md", kind: "installPs", label: "README layout row: install.ps1", pattern: /tests\/test_install\.ps1\s+(\d+) checks/ },
  { file: "README.md", kind: "installSh", label: "README layout row: install.sh", pattern: /tests\/test_install\.sh\s+(\d+) checks/ },
  { file: "README.md", kind: "profiles", label: "README suite table: profiles", pattern: /\| `node tests\/test_profiles\.js` \| (\d+)\/(\d+) \|/, pair: true },
  { file: "README.md", kind: "installPs", label: "README suite table: install.ps1", pattern: /\| `powershell[^|]*test_install\.ps1` \| (\d+)\/(\d+) \|/, pair: true },
  { file: "README.md", kind: "installSh", label: "README suite table: install.sh", pattern: /\| `bash tests\/test_install\.sh` \| (\d+)\/(\d+) \|/, pair: true },
  { file: "AGENTS.md", kind: "profiles", label: "AGENTS suite table: profiles", pattern: /\| `node tests\/test_profiles\.js` \| (\d+) \|/ },
  { file: "AGENTS.md", kind: "installPs", label: "AGENTS suite table: install.ps1", pattern: /\| `powershell[^|]*test_install\.ps1` \| (\d+) \|/ },
  { file: "AGENTS.md", kind: "installSh", label: "AGENTS suite table: install.sh", pattern: /\| `bash tests\/test_install\.sh` \| (\d+) \|/ }
];

const sources = {};
for (const name of ["README.md", "AGENTS.md"]) {
  sources[name] = fs.readFileSync(path.join(ROOT, name), "utf8");
}

for (const claim of claims) {
  const expected = counts[claim.kind];
  if (!expected || !Number.isFinite(expected.Passed)) {
    skipped += 1;
    console.log("  skip  " + claim.label + " (that suite was not run)");
    continue;
  }
  const match = sources[claim.file].match(claim.pattern);
  ok(match !== null, claim.label + ": the row still exists in " + claim.file);
  if (!match) continue;

  const stated = Number(match[1]);
  ok(stated === expected.Passed,
    claim.label + ": says " + stated + ", a real run says " + expected.Passed);
  if (claim.pair) {
    ok(Number(match[2]) === expected.Passed,
      claim.label + ": the N/N pair is inconsistent (" + match[1] + "/" + match[2] + ")");
  }
}

console.log("");
if (failures === 0) {
  console.log("PASS " + (checks - failures) + "/" + checks + " doc counts match" +
    (skipped ? " (" + skipped + " unchecked: suite not run)" : ""));
  process.exit(0);
}
console.log("FAIL " + failures + " of " + checks + " doc counts are stale - update README.md / AGENTS.md");
process.exit(1);
