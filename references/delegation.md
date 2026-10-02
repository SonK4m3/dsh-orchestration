# Delegation contract

What to put in a work packet, and how to keep a fan-out from collapsing into rework.

## Work packet fields

| Field | Why it matters |
| --- | --- |
| Objective | One sentence. If it needs two, the slice is too big. |
| Requirement IDs | Lets you map the result back to what the user asked for. |
| Exclusive write paths | Prevents two agents editing one file. |
| Read-only scope | Explicit when the agent must not change anything. |
| Interface / dependencies | What is frozen, what is not yet decided. |
| Minimal context | Exact files, line ranges, facts. Not the whole conversation. |
| Acceptance checks | How the agent proves it is done. |
| Return format | What you need back to integrate. |

Add deadline or checkpoint only when one was actually supplied.

## Context budget

Pass the minimum that lets the agent succeed. Every extra token in the prompt
reduces the budget available for the actual work, and inherited conversation makes
an agent re-derive conclusions root already holds.

- Prefer specific file paths and line ranges over broad summaries.
- State facts the agent cannot discover, especially decisions made at root.
- Use `subagent_fork` only when the subagent truly needs the full prior reasoning —
  for example, a review that depends on the whole discussion.
- Do not duplicate the delegated investigation at root "just in case". That
  doubles cost and produces two inconsistent answers.

## Ownership rules

- One writer per file at a time.
- Freeze shared interfaces before parallel implementation starts.
- Root keeps architecture, interface definition, and integration. Delegating the
  decision that shapes everything else guarantees an incoherent result.
- Read-only means read-only. An explorer that reports a bug does not fix it.

## Execution discipline

- Fire independent agents in the same message. Waiting for one before starting an
  unrelated one converts parallel work into serial work for no benefit.
- Respect the concurrency cap. Staged agents running at once are not staged.
- While agents run, advance the critical path at root or collect results. Do not
  poll, and do not idle.
- Use `workflow` for many items; use individual `subagent` calls for one or two.

## Verification

Map each requirement to evidence or to an explicitly unresolved item.

- A passing check only covers the boundary it actually exercised. Unit tests are
  not evidence for UI, integration, long-running behavior, or deployment.
- Verify at the boundary that changed: the original reproduction, the contract, the
  rendered interaction, or the live workflow.
- Record pre-existing failures separately so they are not attributed to this work.
- For material risk, use an independent reviewer: give it requirements and
  artifacts, and ask for its own conclusion **before** revealing the
  implementer's stated confidence. Agreement obtained after showing the answer is
  not independent.
- Stop once the affected criteria and required gates pass. More checks past that
  point buy nothing.

## Failure handling

| Situation | Action |
| --- | --- |
| Agent failed | Diagnose at root before retrying. Do not simply re-spawn. |
| Same approach fails twice, no new evidence | Change hypothesis, contract, model, or owner. |
| New dependency appeared | Update the plan, reassign ownership, recheck affected work. |
| Requirement changed | Stop obsolete work immediately; do not let it finish. |
| Tool or model unavailable | Report it, use an authorized fallback, never silently substitute. |
| Cannot finish within limits | Report complete / unverified / blocked; request a scope decision. |

## Prohibited

- Simulating a subagent or inventing its output.
- Claiming a model or capability switch that did not happen.
- Presenting unverified work as verified.
- Concluding that a deadline turned a failing check into a passing one.
