# dsh-orchestration

A [DeepSeek Harness](https://github.com/SonK4m3/dsh-orchestration) kit for organizing
agent and subagent work into an explicit structure **before** delegating: pick a
topology, split by independently verifiable outcomes, assign exclusive file
ownership, hand out work packets, then integrate and verify.

It is four things that fit together:

1. **A skill** (`SKILL.md` + `references/`) that tells an agent how to decide whether
   to split work at all, and what shape to use when it does.
2. **A runnable pipeline** (`scripts/orchestrate.js`) - a DSH `workflow` script body
   with five nodes and a two-tier model policy: cheap models execute, strong models
   plan and review.
3. **Installers** (`setup.ps1`, `setup.sh`) that copy both into a project, or into
   `$DSH_HOME`, and manage one marked region in `AGENTS.md`.
4. **Guides** (`guides/`) covering installation, the six profiles, and the mapping
   from the Codex Astra/Luna orchestrator this kit is modelled on to what DSH
   actually supports.

## Layout

```
SKILL.md                     always-loaded skill body: 7 steps, L0-L3
references/topologies.md     topology diagrams, incl. the two-tier staged pipeline
references/delegation.md     work-packet fields, ownership, verification, failures
assets/work-packet.md        copy-and-fill work-packet template
assets/agents-block.md       body of the AGENTS.md managed region

scripts/orchestrate.js       the pipeline: phases, nodes, pins, result schemas
profiles/<name>/profile.json six profiles: model + effort per stage, host cap

setup.ps1                    Windows installer (PowerShell 5.1+)
setup.sh                     macOS / Linux installer (POSIX bash)

tests/test_profiles.js       272 checks: profile + pipeline consistency
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
`agent(prompt, { model })`. Reasoning effort is written into each prompt as a
request; it becomes a real per-call parameter only when the Host setting
**subagent model selection** is enabled. The installers end by printing that
setting and the `maxActiveSubagents` value the chosen profile expects.

## Profiles

| Profile | root | execution | reviewer | cap |
| --- | --- | --- | --- | --- |
| `pro` (default) | `deepseek-v4-pro` / high | `deepseek-flash` / high | `deepseek-v4-pro` / low | 8 |
| `plus` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-v4-pro` / low | 8 |
| `pro-2-subagents` | `deepseek-v4-pro` / high | `deepseek-flash` / high | `deepseek-v4-pro` / low | 2 |
| `plus-2-subagents` | `deepseek-flash` / max | `deepseek-flash` / low | `deepseek-v4-pro` / low | 2 |
| `pro-max` | `deepseek-v4-pro` / max | `deepseek-flash` / max | `deepseek-v4-pro` / max | 8 |
| `pro-exec-max` | `deepseek-v4-pro` / high | `deepseek-flash` / max | `deepseek-v4-pro` / high | 8 |

The rule behind all six: **judgement gets the strong model, execution gets the cheap
one, and the reviewer is a different model than the implementer.** See
[guides/profiles.md](guides/profiles.md).

## Verification

All three suites are green, and none of them is a smoke test:

| Suite | Result | Notes |
| --- | --- | --- |
| `node tests/test_profiles.js` | 272/272 | Drift-checks the pipeline's embedded profile table against `profiles/`, and asserts the effort ladder, node order, prompt contents, fan-out width versus cap, and failure degradation. |
| `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_install.ps1` | 83/83 | Installs into `.test-install/`, asserts exact file lists, byte-identical copies, idempotency, profile switching, component subsets, user scope, numeric selection, and twelve refusals. |
| `bash tests/test_install.sh` | 108/108 | Same coverage for the POSIX installer, plus a pass with `python3` and `node` removed from `PATH` so its `sed`-based profile reader is exercised. Verified on Linux bash 5.3.9 (WSL Ubuntu); macOS is unexercised. |

An end-to-end run of the pipeline itself was executed through the live `workflow`
tool: five agents, four phases, all five result schemas accepted, execution nodes on
`deepseek-flash` and the reviewer on `deepseek-v4-pro`, exactly as the profile
specifies.

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
