# Work packet template

Copy and fill in before spawning an agent. Delete any line that does not apply.

```
Name / role:
Objective (one sentence):
Requirement IDs:
Write ownership (exclusive paths) — or "READ-ONLY":
Interface contract / frozen decisions:
Dependencies (other tasks, agents, or external):
Minimal context (exact files, line ranges, facts):
Acceptance checks:
Return (changed paths or findings, commands run, actual results, unresolved risks):
Deadline / checkpoint (only if supplied):
```

## Escalate to root when

- The scope conflicts with another workstream.
- A new dependency or interface change appears.
- Behavior is ambiguous and changes the design.
- The same approach failed twice without new evidence.
- A required tool, model, or path is unavailable.

## Return format

Always ask for **actual results**, not summaries of intent:

- Changed paths, or findings with file:line references.
- Commands run and their real output.
- Anything unresolved, blocked, or assumed.
