# dsh-orchestration

A DeepSeek Harness (DSH) skill for organizing agent and subagent work into an
explicit structure **before** delegating.

> Organize agent and subagent work into an explicit structure before delegating:
> choose a topology, split by independently verifiable outcomes, assign exclusive
> file ownership, hand out work packets, then integrate and verify.

## What it covers

- **Topology first** — pick the right shape (L0–L3) for the task before spawning anything.
- **Split by independently verifiable outcomes, not by role** — "one frontend agent,
  one backend agent" is rejected unless the two produce separately checkable results.
- **Exclusive file ownership** per work packet, then integrate and verify.
- **Real DSH primitives** — `subagent`, `subagent_fork`, and the `workflow` tool
  (`pipeline` / `parallel` / `phase`) as the actual fan-out primitive.

## Files

| File | Role |
| --- | --- |
| `SKILL.md` | Always-loaded body: 7 steps from "should I split?" to "adapt the graph". |
| `references/topologies.md` | L0–L3 plus debug / deadline / escalation / changed-scope diagrams. |
| `references/delegation.md` | Work-packet field rationale, ownership, verification, failure table. |
| `assets/work-packet.md` | Copy-and-fill work-packet template. |

## Install

Copy the folder into your skills directory:

```sh
cp -r dsh-orchestration "$HOME/.agents/skills/"
```

On Windows:

```powershell
Copy-Item -Recurse dsh-orchestration "$env:USERPROFILE\.agents\skills\"
```

The next DSH session picks it up in the available-skills catalog.
