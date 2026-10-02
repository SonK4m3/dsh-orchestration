// dsh-orchestration — executable Astra/Luna topology for DeepSeek Harness.
//
// This file is a workflow-tool script BODY, not a Node module. Paste the whole
// file into the `workflow` tool's `script` argument. It has no filesystem,
// network, or timer access; the agents do the work.
//
// Required args: { objective: "<what to build, fix, or investigate>" }
// Optional args: {
//   profile,        // "pro" | "plus" | "pro-2-subagents" | "plus-2-subagents" | "pro-max" | "pro-exec-max"
//   requirements,   // string[] — requirement statements, echoed to every agent as R1..Rn
//   writePaths,     // string — the paths the worker alone may write
//   provider,       // string — override the LLM provider for every node
//   dryRun          // boolean — resolve the plan and return it without spawning anything
// }
//
// What this script does NOT do: it never integrates or declares success. Root
// owns integration and the final boundary check; this script returns evidence.
//
// Model tiers are pinned through the workflow tool's per-node model override.
// Reasoning effort is NOT pinnable there: it is requested in each prompt and
// reported back as "requested", never claimed as runtime-confirmed. The only
// effort values DSH's DeepSeek adapter accepts are off | low | high | max
// (default high); any other value fails the call with UNSUPPORTED_REASONING_EFFORT.

// --- profiles:begin --- (mirrors profiles/*/profile.json; drift-checked by tests/test_profiles.js)
const PROFILES = {
  "pro": {
    "root": { "model": "deepseek-v4-pro", "reasoning_effort": "high" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "reviewer": { "model": "deepseek-v4-pro", "reasoning_effort": "low" },
    "host": { "maxActiveSubagents": 8, "maxDepth": 1 }
  },
  "plus": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "low" },
    "reviewer": { "model": "deepseek-v4-pro", "reasoning_effort": "low" },
    "host": { "maxActiveSubagents": 8, "maxDepth": 1 }
  },
  "pro-2-subagents": {
    "root": { "model": "deepseek-v4-pro", "reasoning_effort": "high" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "reviewer": { "model": "deepseek-v4-pro", "reasoning_effort": "low" },
    "host": { "maxActiveSubagents": 2, "maxDepth": 1 }
  },
  "plus-2-subagents": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "low" },
    "reviewer": { "model": "deepseek-v4-pro", "reasoning_effort": "low" },
    "host": { "maxActiveSubagents": 2, "maxDepth": 1 }
  },
  "pro-max": {
    "root": { "model": "deepseek-v4-pro", "reasoning_effort": "max" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "reviewer": { "model": "deepseek-v4-pro", "reasoning_effort": "max" },
    "host": { "maxActiveSubagents": 8, "maxDepth": 1 }
  },
  "pro-exec-max": {
    "root": { "model": "deepseek-v4-pro", "reasoning_effort": "high" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "reviewer": { "model": "deepseek-v4-pro", "reasoning_effort": "high" },
    "host": { "maxActiveSubagents": 8, "maxDepth": 1 }
  }
};
// --- profiles:end ---

const requested = (args && args.profile) || "pro";
const profileName = Object.prototype.hasOwnProperty.call(PROFILES, requested) ? requested : "pro";
const profile = PROFILES[profileName];

const objective = String((args && args.objective) || "").trim();
if (!objective) {
  return {
    ok: false,
    reason: "args.objective is required: a string describing the work to delegate.",
    availableProfiles: Object.keys(PROFILES)
  };
}

const requirements = Array.isArray(args && args.requirements) ? args.requirements : [];
const requirementList = requirements.length
  ? requirements.map((r, i) => "R" + (i + 1) + ": " + r).join("\n")
  : "(none supplied — derive them from the objective and state each one you assume)";
const writePaths = (args && args.writePaths) || "(declare every path you write, and write nothing outside that list)";
const providerOverride = (args && args.provider) || null;
const fanOutWidth = Math.max(1, Math.min(3, profile.host.maxActiveSubagents || 1));

if (args && args.dryRun) {
  return {
    ok: true,
    dryRun: true,
    profile: profileName,
    objective,
    fanOutWidth,
    nodes: [
      { role: "explorer", model: profile.execution.model, access: "read-only" },
      { role: "researcher", model: profile.execution.model, access: "read-only" },
      { role: "worker", model: profile.execution.model, access: "write" },
      { role: "tester", model: profile.execution.model, access: "write-tests" },
      { role: "reviewer", model: profile.reviewer.model, access: "read-only" }
    ],
    note: "Plan only. No agent was spawned."
  };
}

const pin = (tier) => {
  const options = { model: tier.model };
  if (providerOverride) options.provider = providerOverride;
  return options;
};

const effortLine = (tier) => "REQUESTED REASONING EFFORT: " + tier.reasoning_effort + " (a request, not an enforced setting)";

// Run thunks in bounded waves so the fan-out never exceeds the profile's cap.
async function inWaves(items, width, run) {
  const results = [];
  for (let start = 0; start < items.length; start += width) {
    const wave = items.slice(start, start + width);
    const part = await parallel(wave.map((item, offset) => () => run(item, start + offset)));
    results.push.apply(results, part);
  }
  return results;
}

const explorerSchema = {
  type: "object",
  additionalProperties: false,
  required: ["summary", "affectedPaths", "findings", "unknowns"],
  properties: {
    summary: { type: "string" },
    affectedPaths: { type: "array", items: { type: "string" } },
    findings: { type: "array", items: { type: "string" } },
    unknowns: { type: "array", items: { type: "string" } }
  }
};

const researcherSchema = {
  type: "object",
  additionalProperties: false,
  required: ["summary", "facts", "unknowns"],
  properties: {
    summary: { type: "string" },
    facts: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["claim", "source"],
        properties: { claim: { type: "string" }, source: { type: "string" } }
      }
    },
    unknowns: { type: "array", items: { type: "string" } }
  }
};

const workerSchema = {
  type: "object",
  additionalProperties: false,
  required: ["changedPaths", "summary", "verification", "unresolved"],
  properties: {
    changedPaths: { type: "array", items: { type: "string" } },
    summary: { type: "string" },
    verification: { type: "array", items: { type: "string" } },
    unresolved: { type: "array", items: { type: "string" } }
  }
};

const testerSchema = {
  type: "object",
  additionalProperties: false,
  required: ["passed", "evidence", "failures", "uncovered"],
  properties: {
    passed: { type: "boolean" },
    evidence: { type: "array", items: { type: "string" } },
    failures: { type: "array", items: { type: "string" } },
    uncovered: { type: "array", items: { type: "string" } }
  }
};

const reviewerSchema = {
  type: "object",
  additionalProperties: false,
  required: ["verdict", "defects", "requirementsCovered", "unresolved"],
  properties: {
    verdict: { type: "string", enum: ["accept", "accept-with-findings", "reject"] },
    defects: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["severity", "description", "evidence"],
        properties: {
          severity: { type: "string", enum: ["blocking", "material", "minor"] },
          description: { type: "string" },
          evidence: { type: "string" }
        }
      }
    },
    requirementsCovered: { type: "array", items: { type: "string" } },
    unresolved: { type: "array", items: { type: "string" } }
  }
};

phase("Recon");
log("profile " + profileName + ": explorer + researcher on " + profile.execution.model + ", fan-out width " + fanOutWidth);

const reconned = await inWaves(["explorer", "researcher"], fanOutWidth, async (role) => {
  const common =
    "OBJECTIVE: " + objective +
    "\nREQUIREMENTS:\n" + requirementList +
    "\nSCOPE: read-only. You may read and search; you must not create, edit, or delete any file." +
    "\n" + effortLine(profile.execution) +
    "\nRETURN: the structured object only. Cite real paths. Write \"unknown\" instead of guessing.";

  if (role === "explorer") {
    return agent(
      "ROLE: explorer (read-only)\n" +
        common +
        "\nDELIVERABLE: map what this objective touches — entry points, call paths, existing tests, and every file a change would need to modify.",
      { label: "explorer", phase: "Recon", schema: explorerSchema, ...pin(profile.execution) }
    );
  }
  return agent(
    "ROLE: researcher (read-only)\n" +
      common +
      "\nDELIVERABLE: resolve the external facts this objective depends on — API or version behavior, configuration keys, platform constraints. Each fact needs a source (path or URL) and a version or date.",
    { label: "researcher", phase: "Recon", schema: researcherSchema, ...pin(profile.execution) }
  );
});

const explorer = reconned[0] || null;
const researcher = reconned[1] || null;
const reconGaps = [];
if (!explorer) reconGaps.push("explorer returned no result (spawn failed or schema invalid)");
if (!researcher) reconGaps.push("researcher returned no result (spawn failed or schema invalid)");

phase("Implement");
const worker = await agent(
  "ROLE: worker (single writer)\n" +
    "OBJECTIVE: " + objective +
    "\nREQUIREMENTS:\n" + requirementList +
    "\nWRITE OWNERSHIP: " + writePaths +
    "\nDEPENDENCIES FROM RECON:\nexplorer: " + JSON.stringify(explorer) + "\nresearcher: " + JSON.stringify(researcher) +
    "\n" + effortLine(profile.execution) +
    "\nCONSTRAINTS: edit only the paths you own. Do not add dependencies. If a shared interface must change, report it as a decision for root instead of changing it unilaterally. If recon was insufficient, say so in unresolved rather than inventing facts." +
    "\nRETURN: the structured object only.",
  { label: "worker", phase: "Implement", schema: workerSchema, ...pin(profile.execution) }
);

if (!worker) {
  return {
    ok: false,
    profile: profileName,
    stage: "implement",
    reason: "worker produced no result; nothing was verified and nothing is claimed.",
    recon: { explorer, researcher },
    unresolved: reconGaps.concat(["implementation never completed"])
  };
}

phase("Verify");
const tester = await agent(
  "ROLE: tester (verification)\n" +
    "OBJECTIVE: " + objective +
    "\nREQUIREMENTS:\n" + requirementList +
    "\nCHANGE UNDER TEST: " + JSON.stringify(worker.changedPaths) +
    "\n" + effortLine(profile.execution) +
    "\nSCOPE: you may create or edit test artifacts. Do not edit production code; if it must change, fail the check and report it." +
    "\nRULES: run the checks yourself and report the actual result. A check you did not run is not evidence. List every requirement you could not exercise in uncovered." +
    "\nRETURN: the structured object only.",
  { label: "tester", phase: "Verify", schema: testerSchema, ...pin(profile.execution) }
);

phase("Review");
// The reviewer receives requirements and artifacts — not the worker's own summary.
// It must form an independent conclusion before seeing any implementer confidence.
const reviewer = await agent(
  "ROLE: reviewer (independent, read-only, strong model)\n" +
    "OBJECTIVE: " + objective +
    "\nREQUIREMENTS:\n" + requirementList +
    "\nARTIFACTS: changed paths " + JSON.stringify(worker.changedPaths) +
    "\nTESTER EVIDENCE: " + JSON.stringify(tester) +
    "\nSCOPE: read-only. Inspect the actual diff and tests. Report defects; do not fix them." +
    "\n" + effortLine(profile.reviewer) +
    "\nRULES: reach your own conclusion from the artifacts. Treat the tester report as evidence to check, not truth. Name any requirement you could not verify in unresolved." +
    "\nRETURN: the structured object only.",
  { label: "reviewer", phase: "Review", schema: reviewerSchema, ...pin(profile.reviewer) }
);

const unresolved = reconGaps
  .concat(explorer && explorer.unknowns ? explorer.unknowns : [])
  .concat(researcher && researcher.unknowns ? researcher.unknowns : [])
  .concat(worker.unresolved || [])
  .concat(!tester ? ["tester produced no result: verification is unrun, not passed"] : tester.uncovered || [])
  .concat(!reviewer ? ["reviewer produced no result: no independent assessment exists"] : reviewer.unresolved || []);

return {
  ok: true,
  profile: profileName,
  models: {
    root: profile.root.model,
    execution: profile.execution.model,
    reviewer: profile.reviewer.model
  },
  objective,
  recon: { explorer, researcher },
  implementation: worker,
  verification: tester,
  review: reviewer,
  integration: {
    owner: "root",
    verdict: reviewer ? reviewer.verdict : "unreviewed",
    blockingDefects: reviewer
      ? (reviewer.defects || []).filter((d) => d.severity === "blocking").map((d) => d.description)
      : [],
    nextSteps: [
      "Resolve blocking defects before claiming completion.",
      "Run the boundary check on the path actually affected by this change.",
      "Report verified requirements, unverified requirements, and limits separately."
    ]
  },
  unresolved,
  runtime: { fanOutWidth, maxActiveSubagents: profile.host.maxActiveSubagents }
};
