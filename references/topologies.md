# Topologies

Choose the smallest structure that fits. Roles below are assignments, not model
pins. Every shape inherits the priority order, ownership, and verification rules
from `SKILL.md`.

## Choosing a level

```
Task
 └─ Do the pieces proceed independently?
     ├─ No  → L0  root only
     ├─ One → L1  root + one agent
     ├─ Two → L2  root + two agents
     └─ Several, or material risk → L3  staged
```

File count is not the criterion. Three trivial files in one module are L0 just as
readily as one file.

---

## L0 — root only

```
Root understands requirement → Root inspects and changes → Targeted check → Evidence
```

Use for: a coupled chain, a single outcome, one file, or anything on the blocking
critical path. Delegating here costs a round-trip and loses context for no gain.

## L1 — one bounded specialist

```
Root defines question and scope ─┬─→ Agent: isolated slice
                                 └─→ Root: independent main work
                                     ↓
                          Root integrates → Verify acceptance
```

Use when root has genuinely separate work to advance while the agent runs. If root
would just be waiting, the task belongs at L0.

## L2 — two parallel slices

```
Root freezes interface + ownership
   ├─→ Agent A: slice A
   └─→ Agent B: slice B
        ↓
   Root integrates → Boundary and end-to-end checks
```

Use for two components with separate outputs. **The interface must be frozen before
either worker starts** — signatures, data shapes, file paths. This is the single
most important precondition in this document.

## L3 — staged, for several slices or material risk

```
Root defines invariants + ownership
   ├─→ Explorer: affected flows        (read-only)
   └─→ Researcher: unresolved contract (read-only)
        ↓
   Root approves design and ownership
        ↓
   Workers: disjoint write slices
        ↓
   Root integrates
   ├─→ Tester:   regression evidence
   └─→ Reviewer: independent assessment
        ↓
   Root resolves findings → Final boundary verification
```

Use for auth, migrations, concurrency, broad contract changes, or any work where
independent scrutiny changes the outcome.

For an **audit**, every stage stays read-only and the implementation nodes are
omitted entirely. Do not let an audit edge turn into a write.

Agent count is not fixed. Spawn one per independent, verifiable outcome — no more.

---

## Debug — competing hypotheses, one fix owner

```
Reproduce and minimize → Root lists testable hypotheses
   ├─→ Explorer A tests hypothesis A   (read-only)
   └─→ Explorer B tests hypothesis B   (read-only)
        ↓
   Root reconciles evidence → One owner implements supported fix
        ↓
   Original failure check + regression check
```

Use parallel exploration **only** when there are distinct plausible causes. Never
run competing writers against the same files. The fix has exactly one owner even
when the diagnosis was parallel.

## Deadline — critical path plus verification reserve

```
Requirements + deadline
   ↓
Estimate critical path + checks
   ↓
Feasible with available resources?
   ├─ Yes → Root or critical agent on the critical path
   │         → Helpers where useful → Integration + verification reserve
   └─ No  → Report conflict, request scope or time decision
             → Continue independent authorized work meanwhile
```

A deadline changes scheduling and resource choice. **It never changes the
definition of done.** Always reserve time for verification; a plan with no
verification budget is not a plan.

## Escalation — a cheaper attempt fails

```
Clear bounded task → Economical agent → Acceptance checks
   ├─ Pass → Integrate
   └─ Fail → Root diagnoses
              ├─ New evidence or contract correction → Targeted retry
              └─ No new evidence → Change hypothesis or escalate capability
```

A cheaper first attempt is appropriate only when the task is clear and bounded. If
it fails without producing new information, repeating it at the same capability is
waste — change something real: the hypothesis, the contract, the model, or the
ownership.

## Changed scope or new blocker

```
Active workstreams → New requirement or failure
   ↓
Root updates ledger and dependencies
   ├─→ Stop obsolete work
   └─→ Reuse or add a necessary specialist
        ↓
   Reassign ownership safely → Integrate → Recheck affected requirements
```

Stopping obsolete work is part of the job, not an interruption of it.
