# Profiles

A profile is one JSON file that names the model and reasoning effort for each stage
of the pipeline, plus the concurrency cap. It is the only place in this kit where a
model is chosen, and it is data: nothing here is enforced by DSH, it is a contract
that `orchestrate.js` reads and that the installers write into `AGENTS.md`.

```
profiles/<name>/profile.json      ->  installed as <dest>/orchestration/profile.json
```

## The six shipped profiles

`root` is the planning and integration stage, `execution` is every explorer /
researcher / worker / tester, `reviewer` is the independent check at the end.

| Profile | root | execution | reviewer | cap | Reach for it when |
| --- | --- | --- | --- | --- | --- |
| `pro` | `deepseek-v4-pro` / high | `deepseek-flash` / high | `deepseek-v4-pro` / low | 8 | Default. Plan and review with the strong model, execute cheaply. |
| `plus` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-v4-pro` / low | 8 | The plan is already clear and the work is mechanical; widest fan-out per token. |
| `pro-2-subagents` | `deepseek-v4-pro` / high | `deepseek-flash` / high | `deepseek-v4-pro` / low | 2 | As `pro`, but the machine or the budget only tolerates two live children. |
| `plus-2-subagents` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-v4-pro` / low | 2 | As `plus`, capped at two live children. |
| `pro-max` | `deepseek-v4-pro` / max | `deepseek-flash` / max | `deepseek-v4-pro` / max | 8 | Hard problems end to end: every stage gets maximum effort. |
| `pro-exec-max` | `deepseek-v4-pro` / high | `deepseek-flash` / max | `deepseek-v4-pro` / high | 8 | Cheap model, expensive thinking: long or subtle execution with a strong review. |

Numeric selection is 1-based in the order above, so `-Profile 3` is
`pro-2-subagents` in both installers.

## Fields

```json
{
  "schemaVersion": 1,
  "name": "pro",
  "displayName": "Pro",
  "description": "Strong root and reviewer, cheap high-effort execution.",
  "root":      { "model": "deepseek-v4-pro", "reasoning_effort": "high" },
  "execution": { "model": "deepseek-flash",  "reasoning_effort": "high" },
  "reviewer":  { "model": "deepseek-v4-pro", "reasoning_effort": "low"  },
  "roles": { "explorer": ..., "researcher": ..., "worker": ..., "tester": ... },
  "host": { "maxActiveSubagents": 8, "maxDepth": 1, "requiresSubagentModelSelection": true },
  "notes": [ ... ]
}
```

`root`, `execution` and `reviewer` are single-line objects at 2-space indent and
`host.maxActiveSubagents` is on its own line at 4-space indent. That is not
cosmetic: `setup.sh` falls back to `sed` on exactly those lines when neither
`python3` nor `node` is on `PATH`, and `setup.sh` refuses to install rather than
write an empty pin when a field cannot be read.

`roles` and `notes` are documentation. They exist so a reader does not have to infer
the intent of a profile from three model ids.

## The effort ladder

DSH accepts exactly four values: `off`, `low`, `high`, `max`. The default is `high`.
Any other value fails the call with `UNSUPPORTED_REASONING_EFFORT`.

There is **no** `medium`. That value was in an early draft of this kit and every
profile that used it was rejected at runtime; it is the reason
`tests/test_profiles.js` asserts that no tier uses a value outside the ladder.

Reasoning effort is a request, not a setting. `orchestrate.js` writes the effort
into each node's prompt (`Effort: <value>. ...`), and the value only becomes a real
per-call parameter when the Host setting **subagent model selection** is enabled and
the call passes `reasoning_effort`. The installers print both Host settings that
matter; the profiles stay correct either way, because a pin that cannot be applied
is still honest as a prompt-level request.

## Model ids

| id | name |
| --- | --- |
| `deepseek-v4-pro` | DeepSeek-V4-Pro - stronger agentic coding, knowledge, and difficult reasoning |
| `deepseek-flash` | DeepSeek-V41-Flash - cheap, fast, text and image input |

## Adding a profile

Four edits, in this order:

1. Create `profiles/<name>/profile.json`.
2. Add `<name>` to the ordering in **both** `setup.ps1` (`$ProfileOrder`) and
   `setup.sh` (`PROFILE_ORDER`), at the end so existing numbers do not move.
3. Add the same three pins to the `PROFILES` table inside
   `scripts/orchestrate.js`, between the `// --- profiles:begin ---` and
   `// --- profiles:end ---` markers. `tests/test_profiles.js` loads that slice as
   JSON and fails if a profile on disk is missing from it, or if the pins drift.
4. Run `node tests/test_profiles.js`. It re-checks every profile against the
   embedded table, the ladder, and the cap.

## What a profile cannot do

- Pin a model from a project file. DSH has no project config file and no on-disk
  agent registry, so the only pin that takes effect is the one `orchestrate.js`
  passes to `agent(prompt, { model })`.
- Enforce read-only. A "read-only" role is a prompt contract plus a choice of work
  that does not need to write; DSH does not sandbox an individual child.
- Raise the real concurrency limit. `host.maxActiveSubagents` mirrors the Host
  setting `maxActiveSubagents` (default 8) so the kit's own fan-out width matches
  it; DSH enforces its own limit regardless of what a profile says.
