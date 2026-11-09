---
name: dsh-orchestration
description: >-
  Organize agent and subagent work into an explicit structure before delegating:
  choose a topology, split by independently verifiable outcomes, assign exclusive
  file ownership, hand out work packets, then integrate and verify. Use when a task
  is large enough to split across subagents, when planning parallel work, or when
  deciding whether to delegate at all.
---

# Structuring agent work

Decide the shape of the work before spawning anything. Structure is a decision with
cost, not a default. A wrong topology wastes more context than it saves.

## Priority order

1. Correct and complete fulfillment of the request.
2. Elapsed time and any stated deadline.
3. Tokens and money.

These are ordered priorities, not weights. Cheap output never compensates for a
missing requirement.

## Step 1 — Decide whether to split

Splitting pays off only when work is **independent**. Complexity alone is not a
reason to spawn. Estimate these before choosing a level:

- Can two pieces proceed without waiting on each other?
- Do they touch disjoint files?
- Does each produce an outcome that can be checked on its own?

If the answer is no, stay single-agent. Tightly coupled reasoning, one-file edits,
and urgent blocking work belong at root — delegating them adds round-trips and
loses context.

**Delegation gate.** The three questions above decide whether a *slice* is well
formed. This list decides whether the work belongs in a subagent at all. Delegate
when at least one is true:

- the task spans several files, modules, or components;
- two or more workstreams can proceed without waiting on each other;
- the repository must be explored before anyone can implement;
- implementation and verification benefit from separate contexts;
- the change needs a review by someone who did not write it;
- external or version-specific facts must be verified before the design is chosen;
- the user asked for delegation, subagents, or parallel work.

If none is true, stay at root: delegating a genuinely root-only task spends a
round-trip and loses context. Once the gate is open, spawn at least one real
subagent. Do not describe the delegation, and do not simulate its result.

Use this table to pick a level, then read
[topologies](references/topologies.md) for the matching diagram.

| Level | Shape | Choose when |
| --- | --- | --- |
| L0 | Root only | Coupled chain, one outcome, blocking critical path |
| L1 | Root + 1 agent | One isolated investigation or slice; root advances separately |
| L2 | Root + 2 agents | Two workstreams with separate outputs and safe ownership |
| L3 | Staged agents | Several independent slices, or material risk needing independent review |

There is no fixed agent count at L3. Never spawn more agents than you have
independent, verifiable outcomes. The Astra pipeline is an L3 specialization that
pins a model and a requested effort to every node; see topologies.md.

## Step 2 — Split by outcome, not by role

Split on **independently verifiable outcomes**, not on file count and not on
generic role names. "One agent for the frontend, one for the backend" is only valid
if those two produce separately checkable results.

Split **vertically, not by layer.** Each slice runs end to end through every layer it
needs, so it can be demonstrated and checked alone: "the cache reads its TTL from
config, and one test covers it", not "all the config changes" then "all the cache
changes". A layer split leaves nothing checkable until every layer lands, which is the
most common way a fan-out turns into rework.

Name the **handoff artifact** for every slice: the one output the next step consumes.
Then test the boundary with one question — could a different specialist finish the next
step using only that output, without knowing how it was produced? If not, the slice is
cut in the wrong place; merge it into its consumer.

Before spawning parallel writers, freeze the interface they share. Write down
signatures, data shapes, and file paths. Parallel implementation against an
unfrozen interface guarantees rework.

## Step 3 — Assign ownership

- **One writer owns a file at a time.** No exceptions for "small" edits.
- Read-only work stays read-only. An agent given `read`/`grep`/`glob` must not be
  asked to fix what it finds.
- Root owns architecture, interfaces, and integration. Do not delegate the
  decision that defines the shape of everything else.

## Step 4 — Write a work packet

Every delegation gets a packet. Fill in
[work packet](assets/work-packet.md) and read
[delegation](references/delegation.md) for the contract details.

The packet must state: objective, requirement IDs, handoff artifact, exclusive write
paths or read-only scope, interface and dependencies, minimal context, acceptance
checks, and return format.

**Pass minimal context, not the whole conversation.** A subagent that inherits
everything spends most of its budget rediscovering what root already knows. Give it
the specific facts and file paths it needs. Use `subagent_fork` only when the
subagent genuinely needs the full prior reasoning.

## Step 5 — Execute

- **Start independent work together, in one message.** Sequential spawning of
  independent work is the most common waste in this harness.
- Stay within the runtime concurrency cap. Staged agents are not simultaneous.
- Do useful critical-path work at root while agents run. Do not idle, and do not
  duplicate the investigation you just delegated.
- Use `workflow` when fanning out across many items; use individual `subagent`
  calls for one or two.

## Step 6 — Integrate and verify

Map every requirement to evidence or to an explicit unresolved item.

- Passing one check is not evidence for a boundary you never exercised. Verify at
  the boundary actually affected.
- Record pre-existing failures separately from new ones.
- When an independent assessment matters, give the reviewer the requirements and
  artifacts, and ask for its own conclusion **before** showing it the
  implementer's confidence.
- Stop expanding checks once the affected criteria and required gates pass.
- A deadline never converts a failed or unrun check into a pass.

## Step 7 — Adapt the graph

Reassess when an agent fails, a dependency appears, a requirement changes, a test
fails, or the deadline is at risk.

- Stop obsolete work rather than letting it finish out of politeness.
- Retry the failed unit alone, not the plan. Rerunning accepted work pays twice for one
  failure; give the unit a bounded budget — the pipeline defaults to one attempt and
  caps at three — then change the contract instead of the count.
- Reuse an agent that already holds relevant context.
- If the same approach fails twice with no new evidence, change the hypothesis, the
  contract, the model, or the ownership — not the retry count.
- Add a specialist only for a concrete, named gap.

## Completion gate

Run this before the final answer, not after it. A delegated run is not finished
until every line is true:

- every agent the plan required was actually spawned — none was described or
  simulated;
- every spawned agent either returned a result or failed explicitly, and each
  failure is named;
- no required agent is still running;
- material findings are integrated, and conflicting findings are resolved rather
  than averaged;
- verification was performed on the boundary this change actually affects;
- what is complete, what is unverified, and what is blocked are stated separately.

## Hard rules

- Never simulate a subagent or fabricate its result.
- Never claim a model switch you did not make. Record configured, requested, and
  runtime-confirmed values separately.
- If a requested tool or model is unavailable, say so and use an authorized
  fallback — do not quietly substitute.
- If the work cannot be completed within stated limits, report what is complete,
  what is unverified, and what is blocked; ask for a scope decision instead of
  silently dropping requirements.

## Reporting

Report outcomes first, then verification, then limits. Include topology and model
detail only when asked or when it explains a tradeoff. Do not claim benchmark
parity or savings that were not measured.

## References

- [topologies.md](references/topologies.md) — L0–L3 diagrams, the Astra
  pipeline, and the debug, deadline, and escalation shapes
- [delegation.md](references/delegation.md) — ownership, context budget, review
- [work-packet.md](assets/work-packet.md) — fill-in template
