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
//   writePaths,     // string — the paths the worker alone may write (single-writer mode)
//   slices,         // array of { id, objective, writePaths: string[], acceptance: string[] }
//                   //   — the partition root already decided; one worker per slice, and
//                   //     slices that share a write path are merged into one writer
//   provider,       // string — override the LLM provider for every node
//   evidence,       // "summary" (default) | "full" — how much of each node's report returns
//   dryRun          // boolean — resolve the plan and return it without spawning anything
// }
//
// What this script does NOT do: it never integrates or declares success. Root
// owns integration and the final boundary check; this script returns evidence.
//
// Every shipped profile pins the same model on every tier - deepseek-flash, the
// flash model of the official DeepSeek route (DeepSeek V4.1 Flash). What varies
// between profiles is the requested effort per tier and the fan-out width, not
// the model. A profile that needs a different model edits one table and the
// matching profile.json; the pipeline reads the tier, not a model name.
//
// Model tiers are pinned through the workflow tool's per-node model override.
// Reasoning effort is NOT pinnable there: it is requested in each prompt and
// reported back as "requested", never claimed as runtime-confirmed. The only
// effort values DSH's DeepSeek adapter accepts are off | low | high | max
// (default high); any other value fails the call with UNSUPPORTED_REASONING_EFFORT.

// --- profiles:begin --- (mirrors profiles/*/profile.json; drift-checked by tests/test_profiles.js)
const PROFILES = {
  "pro": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "reviewer": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "host": { "maxActiveSubagents": 8, "maxDepth": 1 }
  },
  "plus": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "low" },
    "reviewer": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "host": { "maxActiveSubagents": 8, "maxDepth": 1 }
  },
  "pro-2-subagents": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "reviewer": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "host": { "maxActiveSubagents": 2, "maxDepth": 1 }
  },
  "plus-2-subagents": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "low" },
    "reviewer": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "host": { "maxActiveSubagents": 2, "maxDepth": 1 }
  },
  "pro-max": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "reviewer": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "host": { "maxActiveSubagents": 8, "maxDepth": 1 }
  },
  "pro-exec-max": {
    "root": { "model": "deepseek-flash", "reasoning_effort": "high" },
    "execution": { "model": "deepseek-flash", "reasoning_effort": "max" },
    "reviewer": { "model": "deepseek-flash", "reasoning_effort": "high" },
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
// "summary" (default) returns each node's decisions plus a clipped one-liner;
// "full" returns the node objects verbatim. The long reports stay in the session
// log either way, but a default run must not push five full reports into root.
const evidenceMode = (args && args.evidence) === "full" ? "full" : "summary";
const fanOutWidth = Math.max(1, Math.min(3, profile.host.maxActiveSubagents || 1));

// Slices: the partition root already decided, instead of one writer for everything.
// The guard is the point of this argument. Two slices that write one path collapse
// into a single writer, and a slice whose done-state cannot be checked is refused
// before any agent spawns - a split that cannot be verified is not a split.
const inputSlices = Array.isArray(args && args.slices) ? args.slices : [];
const sliceProblems = [];
// A wrong type must not degrade into "one writer for everything": root would think
// it split the work and read a single worker's report as the whole change.
if (args && args.slices !== undefined && !Array.isArray(args.slices)) {
  sliceProblems.push("slices: expected an array of { id, objective, writePaths, acceptance }");
}

function normalizeSlices(raw) {
  const seenIds = [];
  return raw.map((slice, index) => {
    const id = String((slice && slice.id) || "slice-" + (index + 1)).trim();
    if (seenIds.indexOf(id) !== -1) sliceProblems.push(id + ": duplicate slice id (a failure would be unattributable)");
    seenIds.push(id);
    const sliceObjective = String((slice && slice.objective) || "").replace(/\s+/g, " ").trim();
    const rawPaths = (slice && slice.writePaths) || [];
    const rawChecks = (slice && slice.acceptance) || [];
    const paths = (Array.isArray(rawPaths) ? rawPaths : []).map((p) => String(p).trim()).filter(Boolean);
    const checks = (Array.isArray(rawChecks) ? rawChecks : []).map((c) => String(c).trim()).filter(Boolean);
    if (!sliceObjective) sliceProblems.push(id + ": objective is empty");
    if (!paths.length) sliceProblems.push(id + ": writePaths is empty (a writer owns at least one path)");
    if (!checks.length) sliceProblems.push(id + ": acceptance is empty (done must be checkable before delegating)");
    return { id, objective: sliceObjective, writePaths: paths, acceptance: checks };
  });
}

function mergeOverlapping(list) {
  const kept = [];
  const merges = [];

  const absorb = (target, slice) => {
    const shared = target.writePaths.filter((p) => slice.writePaths.indexOf(p) !== -1);
    target.objective = target.objective + " / " + slice.objective;
    target.writePaths = target.writePaths.concat(slice.writePaths.filter((p) => target.writePaths.indexOf(p) === -1));
    target.acceptance = target.acceptance.concat(slice.acceptance);
    target.mergedFrom = target.mergedFrom.concat(slice.id);
    merges.push({ kept: target.id, absorbed: slice.id, sharedPaths: shared });
  };

  for (const slice of list) {
    const firstClash = kept.find((other) => other.writePaths.some((p) => slice.writePaths.indexOf(p) !== -1));
    if (!firstClash) {
      kept.push({
        id: slice.id,
        objective: slice.objective,
        writePaths: slice.writePaths.slice(),
        acceptance: slice.acceptance.slice(),
        mergedFrom: []
      });
      continue;
    }
    absorb(firstClash, slice);
    // The new slice can be the bridge between two groups that did not overlap until
    // now. Close that transitively, or two writers still share a path afterwards.
    let closed = false;
    while (!closed) {
      const next = kept.find((other) => other !== firstClash && other.writePaths.some((p) => firstClash.writePaths.indexOf(p) !== -1));
      if (!next) {
        closed = true;
        continue;
      }
      absorb(firstClash, next);
      kept.splice(kept.indexOf(next), 1);
    }
  }
  return { slices: kept, merges };
}

const slicePlan = inputSlices.length ? mergeOverlapping(normalizeSlices(inputSlices)) : null;
const slices = slicePlan ? slicePlan.slices : [];
const planReport = slicePlan
  ? {
      slices: slicePlan.slices.map((slice) => ({
        id: slice.id,
        objective: slice.objective,
        writePaths: slice.writePaths,
        acceptance: slice.acceptance,
        mergedFrom: slice.mergedFrom
      })),
      merges: slicePlan.merges
    }
  : null;

if (sliceProblems.length) {
  return {
    ok: false,
    stage: "validate",
    profile: profileName,
    reason: "args.slices is not delegable. Nothing was spawned, so nothing is claimed.",
    problems: sliceProblems,
    unresolved: sliceProblems
  };
}

if (args && args.dryRun) {
  return {
    ok: true,
    dryRun: true,
    profile: profileName,
    objective,
    fanOutWidth,
    workerCount: slices.length || 1,
    slices: planReport ? planReport.slices : [],
    merges: planReport ? planReport.merges : [],
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

const slicePacket = (slice) =>
  "ROLE: worker (single writer, slice " + slice.id + ")\n" +
  "SLICE OBJECTIVE: " + slice.objective +
  "\nPARENT OBJECTIVE: " + objective +
  "\nREQUIREMENTS:\n" + requirementList +
  "\nWRITE OWNERSHIP (yours alone): " + slice.writePaths.join(", ") +
  "\nACCEPTANCE CHECKS (each one must be shown, not asserted):\n- " + slice.acceptance.join("\n- ") +
  "\nDEPENDENCIES FROM RECON:\nexplorer: " + JSON.stringify(explorer) + "\nresearcher: " + JSON.stringify(researcher) +
  "\n" + effortLine(profile.execution) +
  "\nCONSTRAINTS: edit only the paths you own; every other path belongs to another worker. Do not add dependencies. If a shared interface must change, report it as a decision for root instead of changing it unilaterally. If recon was insufficient, say so in unresolved rather than inventing facts." +
  "\nRETURN: the structured object only.";

let worker = null;
const workerFailures = [];

if (!slices.length) {
  worker = await agent(
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
} else {
  const runs = await inWaves(slices, fanOutWidth, (slice) =>
    agent(slicePacket(slice), {
      label: "worker:" + slice.id,
      phase: "Implement",
      schema: workerSchema,
      ...pin(profile.execution)
    })
  );
  const completed = [];
  runs.forEach((run, index) => {
    if (run) completed.push({ slice: slices[index], run });
    else workerFailures.push("slice " + slices[index].id + " produced no result");
  });
  if (completed.length) {
    const changed = [];
    completed.forEach((entry) => {
      (entry.run.changedPaths || []).forEach((changedPath) => {
        if (changed.indexOf(changedPath) === -1) changed.push(changedPath);
      });
    });
    worker = {
      changedPaths: changed,
      summary: completed.map((entry) => "[" + entry.slice.id + "] " + (entry.run.summary || "")).join(" "),
      verification: completed.reduce((acc, entry) => acc.concat(entry.run.verification || []), []),
      unresolved: completed.reduce((acc, entry) => acc.concat(entry.run.unresolved || []), []).concat(workerFailures)
    };
  }
}

if (!worker) {
  return {
    ok: false,
    profile: profileName,
    evidence: evidenceMode,
    stage: "implement",
    reason: slices.length
      ? "every worker slice failed; nothing was verified and nothing is claimed."
      : "worker produced no result; nothing was verified and nothing is claimed.",
    recon: { explorer, researcher },
    plan: planReport,
    unresolved: reconGaps.concat(workerFailures.length ? workerFailures : ["implementation never completed"])
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
  "ROLE: reviewer (independent, read-only, separate context)\n" +
    "\nYou run the same model as the implementer, so model strength is not what makes this check independent: your fresh context, and the fact that you were not shown the implementer's own account of its work, are." +
    "\nOBJECTIVE: " + objective +
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

// Everything root needs to integrate: the gate decisions, the paths, and the
// counts. Prose is clipped, never dropped silently - pass evidence: "full" for it.
const clip = (value, max) => {
  const flat = String(value == null ? "" : value).replace(/\s+/g, " ").trim();
  return flat.length > max ? flat.slice(0, max - 3) + "..." : flat;
};

const nodes =
  evidenceMode === "full"
    ? { recon: { explorer, researcher }, implementation: worker, verification: tester, review: reviewer }
    : {
        recon: {
          explorer: explorer
            ? { summary: clip(explorer.summary, 240), affectedPaths: explorer.affectedPaths || [], unknowns: explorer.unknowns || [] }
            : null,
          researcher: researcher
            ? { summary: clip(researcher.summary, 240), factCount: (researcher.facts || []).length, unknowns: researcher.unknowns || [] }
            : null
        },
        implementation: {
          changedPaths: worker.changedPaths || [],
          summary: clip(worker.summary, 240),
          checkCount: (worker.verification || []).length,
          sliceCount: slices.length,
          unresolved: worker.unresolved || []
        },
        verification: tester
          ? {
              passed: tester.passed,
              evidenceCount: (tester.evidence || []).length,
              failures: tester.failures || [],
              uncovered: tester.uncovered || []
            }
          : null,
        review: reviewer
          ? {
              verdict: reviewer.verdict,
              defects: (reviewer.defects || []).map((defect) => ({
                severity: defect.severity,
                description: clip(defect.description, 160)
              })),
              requirementsCovered: reviewer.requirementsCovered || [],
              unresolved: reviewer.unresolved || []
            }
          : null
      };

return {
  ok: true,
  profile: profileName,
  evidence: evidenceMode,
  models: {
    root: profile.root.model,
    execution: profile.execution.model,
    reviewer: profile.reviewer.model
  },
  objective,
  plan: planReport,
  recon: nodes.recon,
  implementation: nodes.implementation,
  verification: nodes.verification,
  review: nodes.review,
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
  runtime: { fanOutWidth, maxActiveSubagents: profile.host.maxActiveSubagents, workerCount: slices.length || 1 }
};
