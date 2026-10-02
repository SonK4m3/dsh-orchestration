# Orchestration

This project uses the DSH orchestration kit. When work splits into independent pieces, plan the topology before spawning anything.

## Choose the level first

| Level | When | Shape |
| --- | --- | --- |
| L0 | one file or one module | you do it; no subagents |
| L1 | a few independent lookups | one fan-out, then you integrate |
| L2 | implementation plus independent verification | explorer/researcher -> worker -> tester -> reviewer |
| L3 | multi-stage work across subsystems | the staged pipeline described in the skill |

Split by outcome, not by role. If two pieces do not produce separately checkable results, they are one piece.

## Hard rules

- Read-only is a prompt contract here, not OS isolation. A "read-only" agent can still write; state the limit in its instructions and give it work that does not need to write.
- Pin a model per node only through the `workflow` tool's `agent(prompt, { model })`. Project files cannot pin models: DSH has no project config file and no agent registry.
- Reasoning effort is a *request* written into the prompt. DSH accepts `off | low | high | max` (default `high`); any other value fails the call with `UNSUPPORTED_REASONING_EFFORT`. Never report a requested effort as confirmed.
- Stay within the Host setting `maxActiveSubagents` (default 8; it counts live continuable children only).
- Verification is independent: the tester runs the checks, the reviewer inspects the artifacts, and you integrate. Never claim a check that nobody ran.
- Report verified facts, unverified claims, and limits separately. Write "unverified" rather than implying a pass.

## Where things live

- Instructions: the `dsh-orchestration` skill, discovered at `<project>/.dsh/skills/dsh-orchestration/`.
- Runnable topology: `<project>/.dsh/orchestration/orchestrate.js`, or `$DSH_HOME/orchestration/orchestrate.js` for a user-scope install.
- Work-packet template: the skill's `assets/work-packet.md`.
