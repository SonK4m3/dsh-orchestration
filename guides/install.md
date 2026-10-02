# Install

Two installers produce the same result: `setup.ps1` (Windows PowerShell 5.1+ and
PowerShell 7) and `setup.sh` (macOS and Linux bash). Both write the same three
components to the same destinations, and both manage the same marked region in
`AGENTS.md`.

## Quick start

```powershell
# Windows, from the kit directory
.\setup.ps1 -ListProfiles
.\setup.ps1 -Target C:\code\my-app -Profile pro
```

```sh
# macOS / Linux
./setup.sh --list
./setup.sh --target ~/code/my-app --profile pro
```

Run without a target and the installer asks for one; components are then confirmed
one at a time with `[Y/n]`. `-Profile 3` is the third row of `--list`.

## Options

| `setup.ps1` | `setup.sh` | Meaning |
| --- | --- | --- |
| `-Target <path>` | `--target <path>` | Project to install into. Must exist and must not be the kit itself. |
| `-Profile <name\|n>` | `--profile <name\|n>` | One of the six profiles, by name or 1-based number. Default `pro`. |
| `-Scope Project\|User` | `--scope project\|user` | Install into the project, or into `$DSH_HOME`. Default project. |
| `-Components a,b` | `--components a,b` | Any subset of `skill`, `orchestration`, `AGENTS.md`. Default all. |
| `-NonInteractive` | `--yes` / `-y` | Never prompt. |
| `-DryRun` | `--dry-run` | Print what would be written, change nothing. |
| `-ListProfiles` | `--list` | Print the profile table and exit. |
| `-Help` | `--help` | Usage. |

`-Components AGENTS.md` only touches the managed region and creates no `.dsh`
directory; `-Components skill` installs the skill bundle alone.

## What lands where

| Component | Project scope | User scope |
| --- | --- | --- |
| `skill` | `<target>/.dsh/skills/dsh-orchestration/` - `SKILL.md`, `references/{topologies,delegation}.md`, `assets/work-packet.md` | `$DSH_HOME/skills/dsh-orchestration/` |
| `orchestration` | `<target>/.dsh/orchestration/` - `orchestrate.js`, `profile.json`, `README.md` | `$DSH_HOME/orchestration/` |
| `AGENTS.md` | `<target>/AGENTS.md`, managed region | `$DSH_HOME/AGENTS.md`, managed region |

The skill bundle is exactly five files. Tests / profiles / installers / `.git` are
never copied into the skill directory, and installing twice never nests a second
`references` directory inside the first.

Project scope is the one that matters for a working agent, because DSH ranks skill
roots and reads instructions per directory:

- Skills: `<project>/.dsh/skills` (rank 100) beats `<project>/.agents/skills` (200)
  beats `customSkillDirs` (300) beats `$DSH_HOME/skills` (400) beats
  `~/.agents/skills` (500).
- Instructions: the project root is the nearest ancestor containing `.git`; one
  durable baseline message is assembled from `AGENTS.md` / `CLAUDE.md` from the
  project root down to the working directory, user-global first.

## The managed region

`AGENTS.md` is edited, never replaced. The kit owns one region:

```
<!-- dsh-orchestration:begin -->
# Orchestration
... level table, hard rules, where things live, and the selected profile ...
<!-- dsh-orchestration:end -->
```

- Existing content above and below the region survives; the file is appended to if
  it does not exist.
- Re-running with the same profile rewrites nothing and reports
  `AGENTS.md: already-present`; the file is compared after normalizing line endings.
- A different profile replaces only the region.
- A begin marker with no end marker, a symlinked or junction `AGENTS.md`, a target
  that is a file, or a target that is the kit itself are all refused with exit 1 and
  an explanation, before anything is written.

## After installing

Two Host settings decide how much of a profile is actually applied:

1. **Subagent model selection** - when it is on, `workflow` nodes can pass
   `provider` / `model` / `reasoning_effort` per call. When it is off, the model pin
   in `orchestrate.js` is inert and the profile degrades to a prompt-level request.
2. **`maxActiveSubagents`** (default 8) - set it to the `host.maxActiveSubagents` of
   the installed profile so the kit's fan-out width matches what DSH will allow.

Both installers print these two reminders at the end of a successful install.

## Verify the installers

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_install.ps1
```

```sh
bash tests/test_install.sh
```

Both suites are self-contained: they install into a scratch directory
(`.test-install/`, gitignored), assert the exact file list, byte-compare copied
artifacts, re-run for idempotency, switch profiles, exercise component subsets and
user scope, and check that each refusal exits 1 with its message and leaves the
blocking file untouched. The POSIX suite additionally runs a pass with `python3` and
`node` removed from `PATH`, so the `sed`-based profile reader is covered.

## Uninstall

1. Delete `<target>/.dsh/skills/dsh-orchestration/` and
   `<target>/.dsh/orchestration/` (or the `$DSH_HOME` equivalents).
2. Delete the text between the two markers in `AGENTS.md`, including the markers.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `... is not digitally signed. You cannot run this script` | Unsigned scripts under a `RemoteSigned` policy. Run with `-ExecutionPolicy Bypass`. |
| `setup.ps1` fails with `Unexpected token '$('` | The file acquired a non-ASCII byte. Windows PowerShell 5.1 reads a BOM-less UTF-8 `.ps1` as ANSI, and a decoded curly quote becomes a string delimiter. Keep `.ps1` files pure ASCII with LF endings. |
| `setup.sh` cannot start on Windows | Git/MSYS bash cannot create its signal pipe under the DSH sandbox (a named-pipe denial, win32 error 5). Run the PowerShell installer on Windows, or run `setup.sh` inside WSL: `wsl -d Ubuntu -e bash /mnt/d/.../setup.sh --list`. |
| `could not read '<field>' from <profile>.json` | The profile layout changed, or no JSON parser is available. Install `node` or `python3`. The installer refuses rather than writing a blank pin. |
| `git push` dies with `couldn't create signal pipe` | Git's bundled Cygwin `ssh.exe` cannot start. Point git at the native client: `$env:GIT_SSH = 'C:\Windows\System32\OpenSSH\ssh.exe'`. |
