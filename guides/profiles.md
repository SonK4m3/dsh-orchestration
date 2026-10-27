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
| `pro` | `deepseek-flash` / high | `deepseek-flash` / high | `deepseek-flash` / high | 8 | Default. Every stage at the same effort; nothing is starved. |
| `plus` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-flash` / high | 8 | The plan is the risky part and the work is mechanical: think hardest at the root, type cheaply. |
| `pro-2-subagents` | `deepseek-flash` / high | `deepseek-flash` / high | `deepseek-flash` / high | 2 | As `pro`, but the machine or the budget only tolerates two live children. |
| `plus-2-subagents` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-flash` / high | 2 | As `plus`, capped at two live children. |
| `pro-max` | `deepseek-flash` / max | `deepseek-flash` / max | `deepseek-flash` / max | 8 | Hard problems end to end: every stage gets maximum effort. |
| `pro-exec-max` | `deepseek-flash` / high | `deepseek-flash` / max | `deepseek-flash` / high | 8 | The work is long or subtle: execution maxed, planning and review at the default. |

All six pin the same model on all three tiers. The two axes that still separate them
are **requested effort per tier** and **fan-out width**.

Numeric selection is 1-based in the order above, so `-Profile 3` is
`pro-2-subagents` in both installers.

## Fields

```json
{
  "schemaVersion": 1,
  "name": "pro",
  "displayName": "Pro",
  "description": "One model, high effort on every stage.",
  "root":      { "model": "deepseek-flash", "reasoning_effort": "high" },
  "execution": { "model": "deepseek-flash", "reasoning_effort": "high" },
  "reviewer":  { "model": "deepseek-flash", "reasoning_effort": "high" },
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
the intent of a profile from three tier settings.

## The effort ladder

DSH accepts exactly four values: `off`, `low`, `high`, `max`. The default is `high`.
Any other value fails the call with `UNSUPPORTED_REASONING_EFFORT`.

There is **no** `medium`. That value was in an early draft of this kit and every
profile that used it was rejected at runtime; it is the reason
`tests/test_profiles.js` asserts that no tier uses a value outside the ladder.

Reasoning effort is a request, not a setting. `orchestrate.js` writes the effort
into each node's prompt (`REQUESTED REASONING EFFORT: <value> (a request, not an
enforced setting)`), and the value only becomes a real
per-call parameter when the Host setting **subagent model selection** is enabled and
the call passes `reasoning_effort`. The installers print both Host settings that
matter; the profiles stay correct either way, because a pin that cannot be applied
is still honest as a prompt-level request.

## Model ids

| id | name | use |
| --- | --- | --- |
| `deepseek-flash` | DeepSeek-V41-Flash | The flash model of the official `deepseek-official` route, text and image input. Every shipped profile pins it. |
| `deepseek-v4-pro` | DeepSeek-V4-Pro | The stronger model of the same route. The kit no longer pins it, but a profile may. |
| `deepseek-v4.1-flash` | DeepSeek V4.1 Flash | The explicit versioned id third-party routes use for the same model (OpenCode Zen, OpenRouter). Pin this instead of `deepseek-flash` if that is the id your provider lists. |

`deepseek-flash` and `deepseek-v4.1-flash` are the same model under two route-specific
names. Which string is correct depends on the provider, and a wrong one fails the call
rather than degrading: DSH passes an unknown model id through to the wire, and the
node returns no result, which `orchestrate.js` reports as a failed stage instead of a
pass.

Changing the model for the whole kit is one field in each of the six
`profiles/*/profile.json` files plus the matching lines inside the `PROFILES` slice of
`scripts/orchestrate.js` - the drift check in `tests/test_profiles.js` fails if you
touch only one side.

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
