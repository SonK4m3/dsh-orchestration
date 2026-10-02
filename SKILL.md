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

Use this table to pick a level, then read
[topologies](references/topologies.md) for the matching diagram.

| Level | Shape | Choose when |
| --- | --- | --- |
| L0 | Root only | Coupled chain, one outcome, blocking critical path |
| L1 | Root + 1 agent | One isolated investigation or slice; root advances separately |
| L2 | Root + 2 agents | Two workstreams with separate outputs and safe ownership |
| L3 | Staged agents | Several independent slices, or material risk needing independent review |

There is no fixed agent count at L3. Never spawn more agents than you have
independent, verifiable outcomes.

## Step 2 — Split by outcome, not by role

Split on **independently verifiable outcomes**, not on file count and not on
generic role names. "One agent for the frontend, one for the backend" is only valid
if those two produce separately checkable results.

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

The packet must state: objective, requirement IDs, exclusive write paths or
read-only scope, interface and dependencies, minimal context, acceptance checks,
and return format.

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
- Reuse an agent that already holds relevant context.
- If the same approach fails twice with no new evidence, change the hypothesis, the
  contract, the model, or the ownership — not the retry count.
- Add a specialist only for a concrete, named gap.

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

- [topologies.md](references/topologies.md) — L0–L3 diagrams and the debug,
  deadline, and escalation shapes
- [delegation.md](references/delegation.md) — ownership, context budget, review
- [work-packet.md](assets/work-packet.md) — fill-in template
