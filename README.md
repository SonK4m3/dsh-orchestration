# dsh-orchestration

A [DeepSeek Harness](https://github.com/SonK4m3/dsh-orchestration) kit for organizing
agent and subagent work into an explicit structure **before** delegating: pick a
topology, split by independently verifiable outcomes, assign exclusive file
ownership, hand out work packets, then integrate and verify.

It is four things that fit together:

1. **A skill** (`SKILL.md` + `references/`) that tells an agent how to decide whether
   to split work at all, and what shape to use when it does.
2. **A runnable pipeline** (`scripts/orchestrate.js`) - a DSH `workflow` script body
   with five nodes, all on one model: `deepseek-flash`, the flash model of the
   official route (DeepSeek V4.1 Flash). Profiles differ by requested effort per
   tier and by fan-out width, not by model.
3. **Installers** (`setup.ps1`, `setup.sh`) that copy both into a project, or into
   `$DSH_HOME`, and manage one marked region in `AGENTS.md`.
4. **Guides** (`guides/`) covering installation, the six profiles, and the mapping
   from the Codex Astra/Luna orchestrator this kit is modelled on to what DSH
   actually supports.

## Layout

```
SKILL.md                     always-loaded skill body: 7 steps, L0-L3
references/topologies.md     topology diagrams, incl. the staged Astra pipeline
references/delegation.md     work-packet fields, ownership, verification, failures
assets/work-packet.md        copy-and-fill work-packet template
assets/agents-block.md       body of the AGENTS.md managed region

scripts/orchestrate.js       the pipeline: phases, nodes, pins, result schemas
profiles/<name>/profile.json six profiles: model + effort per stage, host cap

setup.ps1                    Windows installer (PowerShell 5.1+)
setup.sh                     macOS / Linux installer (POSIX bash)

tests/test_profiles.js       279 checks: profile + pipeline consistency
tests/test_install.ps1       83 checks: PowerShell installer
tests/test_install.sh        108 checks: POSIX installer

guides/install.md            install, destinations, Host settings, troubleshooting
guides/profiles.md           the six profiles, the effort ladder, adding one
guides/dsh-mapping.md        upstream Codex concept -> DSH, with source anchors
```

## Quick start

```powershell
# Windows
.\setup.ps1 -ListProfiles
.\setup.ps1 -Target C:\code\my-app -Profile pro
```

```sh
# macOS / Linux
./setup.sh --list
./setup.sh --target ~/code/my-app --profile pro
```

Both are interactive by default, confirm each component, warn before overwriting,
and refuse rather than write through a symlink. Add `-NonInteractive` / `--yes` for
scripted use, `-Scope User` / `--scope user` to install into `$DSH_HOME`, and
`-Components` / `--components` for a subset. Full details in
[guides/install.md](guides/install.md).

## How a run is structured

`orchestrate.js` is pasted into the `workflow` tool's `script` argument and driven
by its `args`: `objective`, `profile`, `requirements`, `writePaths`, `provider`,
`dryRun`. It runs four phases and five nodes.

| Phase | Node | Tier | Result |
| --- | --- | --- | --- |
| Recon | `explorer` | execution | facts read from the repository, with paths |
| Recon | `researcher` | execution | outside evidence, with sources |
| Implement | `worker` | execution | changed paths, a summary, and its own checks |
| Verify | `tester` | execution | pass/fail, evidence, failures, uncovered areas |
| Review | `reviewer` | reviewer | verdict and defects, from the artifacts only |

Every node returns a JSON-schema-validated object, so a malformed answer fails
loudly instead of silently degrading. The reviewer never sees the worker's summary -
it inspects the changed paths and the tester's evidence, which is what makes the
review independent. Root then integrates and reports `unresolved[]` rather than
claiming success.

Model pins come from the profile and are applied through
`agent(prompt, { model })`. Every shipped profile pins `deepseek-flash`; a profile
that needs another model changes one table and the matching `profile.json`, and the
pipeline follows the tier rather than a hardcoded name. Reasoning effort is written
into each prompt as a request; it becomes a real per-call parameter only when the
Host setting **subagent model selection** is enabled. The installers end by printing
that setting and the `maxActiveSubagents` value the chosen profile expects.

## Profiles

| Profile | root | execution | reviewer | cap |
| --- | --- | --- | --- | --- |
| `pro` (default) | `deepseek-flash` / high | `deepseek-flash` / high | `deepseek-flash` / high | 8 |
| `plus` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-flash` / high | 8 |
| `pro-2-subagents` | `deepseek-flash` / high | `deepseek-flash` / high | `deepseek-flash` / high | 2 |
| `plus-2-subagents` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-flash` / high | 2 |
| `pro-max` | `deepseek-flash` / max | `deepseek-flash` / max | `deepseek-flash` / max | 8 |
| `pro-exec-max` | `deepseek-flash` / high | `deepseek-flash` / max | `deepseek-flash` / high | 8 |

The rule behind all six: **one model everywhere; the profiles buy thinking time, not
capability.** Because the review gate can no longer be a stronger model than the
implementer, its independence rests on isolation - it never sees the worker's summary
- and no profile drops it below high effort. See
[guides/profiles.md](guides/profiles.md).

## Verification

All three suites are green, and none of them is a smoke test:

| Suite | Result | Notes |
| --- | --- | --- |
| `node tests/test_profiles.js` | 279/279 | Drift-checks the pipeline's embedded profile table against `profiles/`, and asserts the effort ladder, one model on every tier, the review gate never at low effort, node order, prompt contents, fan-out width versus cap, and failure degradation. |
| `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_install.ps1` | 83/83 | Installs into `.test-install/`, asserts exact file lists, byte-identical copies, idempotency, profile switching, component subsets, user scope, numeric selection, and twelve refusals. |
| `bash tests/test_install.sh` | 108/108 | Same coverage for the POSIX installer, plus a pass with `python3` and `node` removed from `PATH` so its `sed`-based profile reader is exercised. Verified on Linux bash 5.3.9 (WSL Ubuntu); macOS is unexercised. |

An end-to-end run of the pipeline itself was executed once through the live `workflow`
tool, back when the profiles split models: five agents, four phases, all five result
schemas accepted, execution nodes on `deepseek-flash` and the reviewer on
`deepseek-v4-pro`. That live run has **not** been repeated since the move to one model
on every node; what covers the current profiles is the stubbed execution in
`tests/test_profiles.js` (phase order, model pins, prompt contents, fan-out, failure
degradation).

## Requirements

- DeepSeek Harness (the skill is discovered at `<project>/.dsh/skills/`, instructions
  at `<project>/AGENTS.md`).
- Windows PowerShell 5.1 or later, or PowerShell 7, for `setup.ps1`.
- POSIX bash and `sed` for `setup.sh`; `python3` or `node` is used to read profiles
  when present, with a `sed` fallback, and the installer refuses rather than write a
  blank pin.
- `node` only to run the test suites.

## License

Apache-2.0. See [LICENSE](LICENSE).
