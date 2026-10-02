# Upstream (Codex Astra/Luna) to DSH

This kit is shaped like
[donvito/codex-astra-luna-orchestrator](https://github.com/donvito/codex-astra-luna-orchestrator),
but its parts are not the same parts: Codex has per-project config files, per-role
agent TOMLs and OS sandbox modes, and DSH has none of those. This guide records the
mapping, with the DSH source location behind each claim.

Throughout, `<PFX>` is
`C:\Users\THINKPAD X1\AppData\Local\Programs\DeepSeek Harness\resources\app.asar\dsh\node_modules`
and packages are `@deepseek-ai/<name>`. The install ships as one packed
`app.asar`, readable only by running the Electron binary in Node mode.

## Concept mapping

| Upstream (Codex) | DSH | Why |
| --- | --- | --- |
| `.codex/config.toml` profile block | `profiles/<name>/profile.json` plus the two Host settings the installer prints | DSH has **no project config file**. A whole-source search for `dsh.toml`, `.dshrc`, `config.toml`, `dsh.yaml`, `.dsh.json`, `agents/*.toml` finds one unrelated README hit. The only project-scoped paths DSH reads are `<project>/.dsh/skills` and `AGENTS.md`. Configuration is Cordis YAML patch layers under `$DSH_HOME` plus a profile `package.json`. |
| `.codex/agents/*.toml` with `name`, `description`, `model`, `model_reasoning_effort`, `sandbox_mode`, `developer_instructions` | a **work packet**: role, instructions, file ownership, output contract, and a model pin passed to `agent(prompt, { model })` | There is **no on-disk agent registry**. Agent presets are Cordis YAML plugin rows (`dsh-agent-preset/README.md:28-46`). The per-call input schema of the subagent tool is only `description` and `prompt`, plus `provider` / `model` / `reasoning_effort` / `run_in_background` when model selection is enabled (`dsh-tool-subagent/lib/index.js:401-430`). There is no per-call system prompt, tool list, or label field. |
| Per-role `model` + `model_reasoning_effort` | `agent(prompt, { model })` in the `workflow` script; effort written into the prompt as a request | Models: `deepseek-v4-pro`, `deepseek-flash` (`dsh-llm-deepseek/lib/index.js:42-54`). Ladder: `off`, `low`, `high`, `max`, default `high` (`:313-318`). Effort is an opaque adapter-owned string (`dsh-llm/lib/index.js:930`) and reaches the wire as `output_config.effort`; an unsupported explicit value fails with `UNSUPPORTED_REASONING_EFFORT` (`dsh-llm-deepseek/lib/index.js:1700`, `dsh-llm/lib/index.js:2182`). |
| `sandbox_mode = "read-only"` | a prompt contract, not isolation | DSH does not sandbox an individual child. A read-only role is enforced by instructions plus a choice of work that needs no writes. |
| `max_concurrent = 4` | Host setting `maxActiveSubagents` (default **8**), mirroring `host.maxActiveSubagents` in the profile, plus the fan-out width the script chooses | It counts live continuable children only; one-shot and external-provider runs are exempt. At capacity, creation or cold resume fails with `ACTIVATION_LIMIT_REACHED` (`dsh-subagent/README.md:51-55`, code `:759`, `:786`, `:970`). `maxDepth` (default 1) is separate. |
| The upstream caller loop that sequences roles in one long session | the `workflow` tool: `pipeline` (no barrier between stages), `parallel` (barrier), `phase()`, `log()`, and JSON-Schema-validated results | This is DSH-native and has no upstream equivalent. `scripts/orchestrate.js` is a workflow script body. |
| Roles as separate agent sessions | `subagent` (continuable by default), `subagent_fork` (one-shot, inherits the whole conversation), `workflow` nodes | Shipped composition: `subagent` = provider `spawn`, continuable (`dsh-base/cordis.patch.yml:370-375`); `subagent_fork` = provider `fork`, one-shot, deliberately no model selection (`:383-388`). Depth errors read `subagent depth N exceeds maxDepth M` (`dsh-subagent/lib/index.js:384`). |
| `scripts/token_usage.py` | **dropped** | Session records are `~/.dsh/sessions/<project-slug>/<session>/session.v4.jsonl.zstd` (zstd-compressed JSONL) plus `~/.dsh/storages/sessions/<id>.json`; neither shape is a documented API, so a token report built on them would be guesswork. |
| `guides/*`, `AGENTS.md` install, `setup.ps1` / `setup.sh` | `guides/*`, kit-root `AGENTS.md`, `setup.ps1`, `setup.sh` | Same shape: confirm each component, warn before overwriting, never touch a symlinked target, edit `AGENTS.md` in place rather than replacing it. |

## Profile name mapping

Upstream ships six profiles; this kit ships six profiles with the same idea (root
model, execution model, review model, concurrency) but names them after the axis that
differs, so that a name never implies an effort level it does not set.

| Upstream | This kit |
| --- | --- |
| `pro` | `pro` |
| `plus` | `plus` |
| `pro-max-2-subagents` | `pro-2-subagents` (cap 2, high effort) and `pro-max` (max effort, cap 8) |
| `plus-max-2-subagents` | `plus-2-subagents` (cap 2) and `pro-max` |
| `GPT6-SolMax-LunaMax` | `pro-max` |
| `GPT6-SolMedium-LunaMax` | `pro-exec-max` |

`pro` and `plus` keep their upstream names and meaning. The four others are split by
the two axes the upstream names bundle: concurrency cap, and maximum-versus-high
effort.

## Verified DSH facts behind the kit

- **Models**: `DEFAULT_MODELS` = `deepseek-flash` (DeepSeek-V41-Flash, text+image) and
  `deepseek-v4-pro` (DeepSeek-V4-Pro), replaceable through the adapter's `models`
  field. Default route is `provider: deepseek-official`, `model: deepseek-flash`
  (`dsh-base/cordis.patch.yml:82-86`).
- **Reasoning effort**: `off | low | high | max`; default `high`; there is no
  `medium`. The base composition leaves `modelSelectionSettings` unset, so per-call
  `provider` / `model` / `reasoning_effort` are only exposed when the Host setting
  **subagent model selection** is enabled (`dsh-tool-subagent/README.md:47,67`; UI
  namespace `dsh-client-ui-settings-subagent/lib/index.js:6`).
- **Workflow hooks available to a script**: `agent(prompt, {label, phase, schema,
  provider, model})`, `pipeline(items, ...stages)` with no barrier between stages,
  `parallel(thunks)`, `phase(title)`, `log(message)`, and the `args` global. A stage
  that throws drops that item to `null` and skips its remaining stages; a misused
  hook ends the whole script.
- **Instructions**: candidates `AGENTS.md`, `CLAUDE.md`, local overlays
  `AGENTS.local.md`, `CLAUDE.local.md`, plus user-global `<dshHome>/AGENTS.md`
  (`dsh-agent-instructions/lib/index.js:17,18,141`). Project root is the nearest
  ancestor containing `.git` (else the working directory). One durable baseline
  message is assembled broad-to-specific from the project root down to the session
  working directory, and reconciled on resume. `@path` imports, lowercase filenames
  and `.claude/rules/` are not interpreted.
- **Skills**: `<root>/<name>/SKILL.md` or `<root>/<name>.md` at the **top level** of a
  scanned root; a nested `**/SKILL.md` is deliberately not discovered
  (`dsh-skill-filesystem/README.md:36`). Roots by rank: `<project>/.dsh/skills` (100),
  `<project>/.agents/skills` (200), `customSkillDirs` (300), `<dshHome>/skills` (400),
  `<agentsHome>/skills` (500), bundled (600). Frontmatter requires kebab-case `name`
  and `description`; an invalid value drops the whole skill with a warning and no
  model-facing diagnostic.
- **CLI**: the only real subcommand is `plugin` (`dsh/lib/bin.js:116-117`). There is
  no `init`, `install` or `skill` subcommand, which is why installing a project skill
  means writing `<project>/.dsh/skills/<name>/SKILL.md` yourself - or running
  `setup.ps1` / `setup.sh` from this kit.

## Unverified

- Whether `modelSelectionSettings: true` can be set from a profile
  `cordis.patch.yml` (the field exists in the tool schema; no shipped row uses it).
- The `workflow` tool's own concurrency caps - unmeasured.
- Where user settings persist per key on disk.
- `setup.sh` was verified on Linux bash 5.3.9 only; macOS (bash 3.2, BSD userland)
  has not been exercised.
