#!/usr/bin/env node
// Tests for the DSH-native orchestration kit.
//
//   node tests/test_profiles.js
//
// Verifies three things, with no dependencies:
//   1. Every profiles/<name>/profile.json is valid and internally consistent.
//   2. The PROFILES table embedded in scripts/orchestrate.js has not drifted
//      from those JSON files.
//   3. scripts/orchestrate.js is syntactically valid AND behaves correctly when
//      executed against stubbed hooks: node order, model pins, fan-out width,
//      failure degradation, and reviewer independence.

const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const PROFILES_DIR = path.join(ROOT, "profiles");
const SCRIPT_PATH = path.join(ROOT, "scripts", "orchestrate.js");

const MODELS = ["deepseek-flash", "deepseek-v4-pro"];
const EFFORTS = ["off", "low", "high", "max"];
const ACCESS = ["read-only", "write", "write-tests"];
const ALLOWED_SCHEMA_KEYWORDS = new Set([
  "type", "properties", "required", "additionalProperties", "items", "enum", "const", "oneOf"
]);

let failures = 0;
let checks = 0;

function ok(condition, message) {
  checks += 1;
  if (!condition) {
    failures += 1;
    console.log("  FAIL  " + message);
  }
}

function section(title) {
  console.log("\n== " + title);
}

// ---------------------------------------------------------------- validators

function checkSchemaKeywords(schema, where, errors) {
  for (const key of Object.keys(schema)) {
    if (!ALLOWED_SCHEMA_KEYWORDS.has(key)) errors.push(where + ': unsupported keyword "' + key + '"');
  }
  if (schema.properties) {
    for (const [name, child] of Object.entries(schema.properties)) {
      checkSchemaKeywords(child, where + "." + name, errors);
    }
  }
  if (schema.items) checkSchemaKeywords(schema.items, where + "[]", errors);
  if (schema.oneOf) schema.oneOf.forEach((child, i) => checkSchemaKeywords(child, where + ".oneOf[" + i + "]", errors));
}

function validate(value, schema, where, errors) {
  if (schema.const !== undefined) ok(value === schema.const, where + " must equal " + JSON.stringify(schema.const));
  if (schema.enum && !schema.enum.includes(value)) errors.push(where + ": " + JSON.stringify(value) + " is not one of " + schema.enum.join(", "));
  if (schema.oneOf) {
    const matched = schema.oneOf.some((child) => {
      const inner = [];
      validate(value, child, where, inner);
      return inner.length === 0;
    });
    if (!matched) errors.push(where + ": matched none of the oneOf branches");
    return;
  }
  switch (schema.type) {
    case "object": {
      if (typeof value !== "object" || value === null || Array.isArray(value)) {
        errors.push(where + ": expected an object");
        return;
      }
      for (const name of schema.required || []) {
        if (!(name in value)) errors.push(where + ": missing required field " + name);
      }
      if (schema.additionalProperties === false) {
        for (const name of Object.keys(value)) {
          if (!(schema.properties || {})[name]) errors.push(where + ': unexpected field "' + name + '"');
        }
      }
      for (const [name, child] of Object.entries(schema.properties || {})) {
        if (name in value) validate(value[name], child, where + "." + name, errors);
      }
      return;
    }
    case "array": {
      if (!Array.isArray(value)) {
        errors.push(where + ": expected an array");
        return;
      }
      value.forEach((item, i) => validate(item, schema.items || {}, where + "[" + i + "]", errors));
      return;
    }
    case "string":
      if (typeof value !== "string") errors.push(where + ": expected a string");
      return;
    case "boolean":
      if (typeof value !== "boolean") errors.push(where + ": expected a boolean");
      return;
    default:
      return;
  }
}

// ------------------------------------------------------- profile.json checks

section("profiles/*/profile.json");

const profileDirs = fs
  .readdirSync(PROFILES_DIR, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

ok(profileDirs.length === 6, "expected 6 profile directories, found " + profileDirs.length + ": " + profileDirs.join(", "));

const profiles = {};
for (const dir of profileDirs) {
  const file = path.join(PROFILES_DIR, dir, "profile.json");
  ok(fs.existsSync(file), dir + "/profile.json exists");
  let data;
  try {
    data = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    ok(false, dir + "/profile.json parses as JSON: " + error.message);
    continue;
  }
  profiles[dir] = data;

  ok(data.schemaVersion === 1, dir + ": schemaVersion is 1");
  ok(data.name === dir, dir + ": name matches its directory");
  ok(typeof data.displayName === "string" && data.displayName.length > 0, dir + ": displayName is a non-empty string");
  ok(typeof data.description === "string" && data.description.length > 0, dir + ": description is a non-empty string");

  for (const tier of ["root", "execution", "reviewer"]) {
    const value = data[tier];
    ok(value && typeof value === "object", dir + ": tier " + tier + " is present");
    if (!value) continue;
    ok(MODELS.includes(value.model), dir + ": " + tier + ".model is a declared DSH model (" + value.model + ")");
    ok(EFFORTS.includes(value.reasoning_effort), dir + ": " + tier + ".reasoning_effort is supported (" + value.reasoning_effort + ")");
  }

  const roles = data.roles || {};
  ok(
    JSON.stringify(Object.keys(roles).sort()) === JSON.stringify(["explorer", "researcher", "tester", "worker"]),
    dir + ": roles are exactly explorer, researcher, tester, worker"
  );
  for (const [role, spec] of Object.entries(roles)) {
    ok(ACCESS.includes(spec.access), dir + ": " + role + " access is a known kind (" + spec.access + ")");
  }
  ok(roles.explorer && roles.explorer.access === "read-only", dir + ": explorer is read-only");
  ok(roles.researcher && roles.researcher.access === "read-only", dir + ": researcher is read-only");
  ok(roles.worker && roles.worker.access === "write", dir + ": worker holds write ownership");
  ok(roles.tester && roles.tester.access === "write-tests", dir + ": tester is limited to test artifacts");

  const host = data.host || {};
  ok(Number.isSafeInteger(host.maxActiveSubagents) && host.maxActiveSubagents >= 1 && host.maxActiveSubagents <= 8, dir + ": maxActiveSubagents is an integer in 1..8");
  ok(host.maxDepth === 1, dir + ": maxDepth is 1");
  ok(host.requiresSubagentModelSelection === true, dir + ": records that per-call model selection must be enabled");

  ok(Array.isArray(data.notes) && data.notes.length > 0, dir + ": notes is a non-empty array");

  // "off" is legal in DSH but would silently strip reasoning from a role.
  ok(
    [data.root, data.execution, data.reviewer].every((tier) => tier && tier.reasoning_effort !== "off"),
    dir + ": reasoning stays enabled for root, execution, and reviewer"
  );

  // The review gate is only independent if it is not the model that did the work.
  ok(data.reviewer.model !== data.execution.model, dir + ": reviewer model differs from the execution model");
}

// ------------------------------------------- embedded table drift + execution

section("scripts/orchestrate.js");

const source = fs.readFileSync(SCRIPT_PATH, "utf8");
const beginMarker = source.indexOf("// --- profiles:begin");
const endMarker = source.indexOf("// --- profiles:end ---");
ok(beginMarker !== -1 && endMarker !== -1 && endMarker > beginMarker, "script carries the profiles:begin/end markers");

let embedded = null;
if (beginMarker !== -1 && endMarker !== -1) {
  const slice = source.slice(beginMarker, endMarker);
  const first = slice.indexOf("{");
  const last = slice.lastIndexOf("}");
  ok(first !== -1 && last > first, "the embedded table is delimited by braces");
  try {
    embedded = JSON.parse(slice.slice(first, last + 1));
  } catch (error) {
    ok(false, "the embedded PROFILES table is JSON-parseable: " + error.message);
  }
}

if (embedded) {
  ok(
    JSON.stringify(Object.keys(embedded).sort()) === JSON.stringify(profileDirs),
    "the embedded table lists exactly the profile directories"
  );
  for (const dir of profileDirs) {
    const file = profiles[dir];
    const table = embedded[dir];
    if (!file || !table) continue;
    for (const tier of ["root", "execution", "reviewer"]) {
      ok(
        JSON.stringify(table[tier]) === JSON.stringify({ model: file[tier].model, reasoning_effort: file[tier].reasoning_effort }),
        dir + ": embedded " + tier + " has not drifted from profile.json"
      );
    }
    ok(
      JSON.stringify(table.host) ===
        JSON.stringify({
          maxActiveSubagents: file.host.maxActiveSubagents,
          maxDepth: file.host.maxDepth
        }),
      dir + ": embedded host config has not drifted from profile.json"
    );
  }
}

// Stubbed hook environment: the real workflow tool's documented contract.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function makeStubs(options) {
  const settings = options || {};
  const calls = [];
  const parallelArities = [];

  const results = {
    explorer: { summary: "explorer summary", affectedPaths: ["src/a.js"], findings: ["entry point is src/a.js"], unknowns: [] },
    researcher: { summary: "researcher summary", facts: [{ claim: "config key is X", source: "docs/x.md" }], unknowns: [] },
    worker: {
      changedPaths: ["src/a.js"],
      summary: "WORKER-CONFIDENCE-MARKER changed src/a.js",
      verification: ["node --check src/a.js"],
      unresolved: []
    },
    tester: { passed: true, evidence: ["ran the suite: 12 passed"], failures: [], uncovered: ["no load test was attempted"] },
    reviewer: { verdict: "accept", defects: [], requirementsCovered: ["R1"], unresolved: [] }
  };

  const agent = async (prompt, opts) => {
    if (typeof prompt !== "string" || prompt.trim().length === 0) throw new Error("agent: prompt must be a non-empty string");
    if (!opts || typeof opts.label !== "string" || opts.label.length === 0) throw new Error("agent: opts.label is required");
    if (opts.schema) checkSchemaKeywords(opts.schema, "schema(" + opts.label + ")", []);
    calls.push({ label: opts.label, model: opts.model, provider: opts.provider, phase: opts.phase, prompt, schema: opts.schema });
    if ((settings.fail || []).includes(opts.label)) return null;
    return opts.schema ? results[opts.label] : "text result";
  };

  const parallel = async (thunks) => {
    if (!Array.isArray(thunks)) throw new Error("parallel: expects an array of thunks");
    parallelArities.push(thunks.length);
    const out = [];
    for (const thunk of thunks) {
      if (typeof thunk !== "function") throw new Error("parallel: every entry must be a function");
      try {
        out.push(await thunk());
      } catch {
        out.push(null);
      }
    }
    return out;
  };

  const pipeline = async () => {
    throw new Error("pipeline: this script must not call it");
  };
  const phase = (title) => {
    if (typeof title !== "string" || title.length === 0) throw new Error("phase: title must be a non-empty string");
  };
  const log = (message) => {
    if (typeof message !== "string") throw new Error("log: message must be a string");
  };

  return { agent, parallel, pipeline, phase, log, calls, parallelArities };
}

function runScript(scriptArgs, options) {
  const stubs = makeStubs(options);
  const runner = new AsyncFunction("agent", "pipeline", "parallel", "phase", "log", "args", source);
  return Promise.resolve(
    runner(stubs.agent, stubs.pipeline, stubs.parallel, stubs.phase, stubs.log, scriptArgs)
  ).then((result) => ({ result, stubs }));
}

(async () => {
  // 1. Syntax and dry run.
  const dry = await runScript({ objective: "make the widget cache invalidate correctly", dryRun: true });
  ok(dry.stubs.calls.length === 0, "dryRun spawns no agents");
  ok(dry.result.ok === true && dry.result.dryRun === true, "dryRun reports a resolved plan");
  ok(Array.isArray(dry.result.nodes) && dry.result.nodes.length === 5, "the plan names all five nodes");
  ok(dry.result.nodes.some((node) => node.role === "reviewer" && node.access === "read-only"), "the plan marks the reviewer read-only");

  // 2. Missing objective is refused, not guessed.
  const empty = await runScript({});
  ok(empty.result.ok === false, "an empty objective is refused");
  ok(Array.isArray(empty.result.availableProfiles) && empty.result.availableProfiles.length === 6, "the refusal lists the available profiles");

  // 3. Happy path on the default profile.
  const happy = await runScript({ objective: "make the widget cache invalidate correctly", requirements: ["cache must expire", "no new dependencies"], writePaths: "src/cache.js" });
  const result = happy.result;
  const stubs = happy.stubs;
  ok(result.ok === true, "happy path reports ok");
  ok(
    JSON.stringify(stubs.calls.map((call) => call.label)) === JSON.stringify(["explorer", "researcher", "worker", "tester", "reviewer"]),
    "nodes run explorer → researcher → worker → tester → reviewer (got " + stubs.calls.map((c) => c.label).join(" → ") + ")"
  );
  ok(result.profile === "pro", "default profile is pro");
  for (const call of stubs.calls) {
    ok(typeof call.model === "string", call.label + " received an explicit model pin (" + call.model + ")");
    ok(call.model === profiles.pro.execution.model || call.model === profiles.pro.reviewer.model, call.label + " model is one of the profile's declared models");
  }
  ok(stubs.calls.find((c) => c.label === "worker").model === profiles.pro.execution.model, "worker runs the execution model");
  ok(stubs.calls.find((c) => c.label === "reviewer").model === profiles.pro.reviewer.model, "reviewer runs the reviewer model");
  for (const call of stubs.calls) {
    ok(call.prompt.includes("make the widget cache invalidate correctly"), call.label + " prompt carries the objective");
    ok(call.prompt.includes("R1") && call.prompt.includes("R2"), call.label + " prompt carries the numbered requirements");
  }
  ok(stubs.calls.find((c) => c.label === "worker").prompt.includes("src/cache.js"), "the worker prompt states its write ownership");
  const reviewerPrompt = stubs.calls.find((c) => c.label === "reviewer").prompt;
  ok(!reviewerPrompt.includes("WORKER-CONFIDENCE-MARKER"), "the reviewer never sees the worker's own summary (independence)");
  ok(reviewerPrompt.includes("ran the suite: 12 passed"), "the reviewer does see the tester's evidence");
  for (const call of stubs.calls.filter((c) => c.label !== "worker")) {
    ok(/read-only|test artifacts/.test(call.prompt), call.label + " prompt states its access limit");
  }
  ok(result.integration.owner === "root", "integration stays with root");
  ok(result.integration.verdict === "accept", "the reviewer verdict is surfaced to root");
  ok(result.unresolved.includes("no load test was attempted"), "the tester's uncovered ground is surfaced as unresolved");

  // Schemas must accept well-formed agent results.
  for (const call of stubs.calls) {
    const errors = [];
    checkSchemaKeywords(call.schema, call.label, errors);
    validate(
      {
        explorer: { summary: "s", affectedPaths: ["p"], findings: ["f"], unknowns: [] },
        researcher: { summary: "s", facts: [{ claim: "c", source: "u" }], unknowns: [] },
        worker: { changedPaths: ["p"], summary: "s", verification: ["v"], unresolved: [] },
        tester: { passed: true, evidence: ["e"], failures: [], uncovered: [] },
        reviewer: { verdict: "accept", defects: [{ severity: "blocking", description: "d", evidence: "e" }], requirementsCovered: [], unresolved: [] }
      }[call.label],
      call.schema,
      call.label,
      errors
    );
    ok(errors.length === 0, call.label + " schema is keyword-clean and accepts a well-formed result (" + errors.join("; ") + ")");
  }

  // 4. The fan-out honours the profile's concurrency cap.
  const capped = await runScript({ objective: "check the confluence cap", profile: "plus-2-subagents" });
  ok(capped.result.profile === "plus-2-subagents", "the requested profile is honoured");
  ok(capped.result.runtime.fanOutWidth === 2, "a cap of 2 narrows the fan-out to 2");
  ok(Math.max(...capped.stubs.parallelArities) <= 2, "no parallel wave exceeds the cap");
  const wide = await runScript({ objective: "check the wide cap", profile: "pro" });
  ok(wide.result.runtime.fanOutWidth === 3, "the default profile fans out 3 wide");

  // 5. Failure degradation is reported, never simulated.
  const noWorker = await runScript({ objective: "worker failure path" }, { fail: ["worker"] });
  ok(noWorker.result.ok === false, "a failed worker stops the run");
  ok(noWorker.result.stage === "implement", "the failure names the stage");
  ok(noWorker.stubs.calls.some((c) => c.label === "tester") === false, "no tester is spawned without an implementation");
  ok(
    JSON.stringify(noWorker.result.unresolved).includes("implementation never completed"),
    "the failure is reported as unresolved work"
  );

  const noTester = await runScript({ objective: "tester failure path" }, { fail: ["tester"] });
  ok(noTester.result.ok === true, "a failed tester does not fake a pass");
  ok(noTester.result.verification === null, "the missing verification is recorded as null");
  ok(
    noTester.result.unresolved.some((item) => item.includes("verification is unrun, not passed")),
    "unrun verification is stated in those words"
  );

  const noReviewer = await runScript({ objective: "reviewer failure path" }, { fail: ["reviewer"] });
  ok(noReviewer.result.integration.verdict === "unreviewed", "a missing review is not reported as accepted");

  // 6. Every declared profile is runnable end to end.
  for (const dir of profileDirs) {
    const run = await runScript({ objective: "profile sweep", profile: dir });
    ok(run.result.ok === true, "profile " + dir + " completes a stubbed run");
    ok(run.stubs.calls.length === 5, "profile " + dir + " spawns exactly five nodes");
  }

  console.log("\n" + (failures === 0 ? "PASS" : "FAIL") + " — " + (checks - failures) + "/" + checks + " checks passed");
  process.exit(failures === 0 ? 0 : 1);
})().catch((error) => {
  console.log("\nFAIL — unexpected error: " + error.stack);
  process.exit(1);
});
