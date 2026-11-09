# Working in the dsh-orchestration kit

This repository **is** the kit: a DSH skill for structuring agent work, a runnable
pipeline, installers that copy both into a project, and the guides that explain them.
Read [README.md](README.md) first; the notes below are the rules that are easy to
break.

## Layout

| Path | Role |
| --- | --- |
| `SKILL.md`, `references/`, `assets/` | The skill bundle. Installed into `<target>/.dsh/skills/dsh-orchestration/`. |
| `scripts/orchestrate.js` | Workflow-script body: phases, nodes, model pins, result schemas. Installed into `<target>/.dsh/orchestration/`. |
| `profiles/<name>/profile.json` | One profile: root / execution / reviewer model + effort, and the host cap. One of these is installed as `orchestration/profile.json`. |
| `assets/agents-block.md` | Body of the `AGENTS.md` managed region, minus the generated profile section. |
| `setup.ps1`, `setup.sh` | Installers. Same components, destinations, markers, refusals. |
| `tests/test_profiles.js`, `tests/test_install.ps1`, `tests/test_install.sh` | The three suites. |
| `tests/wsl-run.sh` | Runs the POSIX suite through WSL, from Windows. |
| `tests/run-all.ps1` | Every suite plus the documentation-count check. The pre-commit hook and CI both call it. |
| `tools/asar-slice.js`, `tools/session-probe.js` | Read the packed DSH sources and the session records. Kit-only: the installers do not copy `tools/`. |
| `guides/` | Install, profiles, and the upstream-to-DSH mapping. |

## Rules for changes

1. **Both installers, always.** `setup.ps1` and `setup.sh` must produce the same
   `AGENTS.md` region and the same file layout. A change to one is a change to both,
   and to the matching assertions in both install tests.
2. **Changing a pin is two edits, plus the drift check:** the `profiles/*/profile.json`
   files you mean to change, and the matching lines inside the `PROFILES` slice between
   the `// --- profiles:begin ---` / `// --- profiles:end ---` markers in
   `scripts/orchestrate.js`. Then run `node tests/test_profiles.js`, which
   drift-checks the embedded slice against the files on disk.
3. **Adding or renaming a profile is four edits:** the new
   `profiles/<name>/profile.json`; `$ProfileOrder` in `setup.ps1`; `PROFILE_ORDER` in
   `setup.sh`; the same `PROFILES` slice. Those two order lists change only when a
   profile is added or renamed, never when a pin moves.
4. **`.ps1` files stay pure ASCII with LF endings.** Windows PowerShell 5.1 reads a
   BOM-less UTF-8 `.ps1` as ANSI, and a decoded curly quote is a string delimiter to
   it - that exact accident once broke `setup.ps1` at the first em dash.
   `tests/test_install.ps1` asserts no byte above `0x7F` in itself and in `setup.ps1`.
   `.gitattributes` pins every text file to LF (`* text=auto eol=lf`) because git
   here has `core.autocrlf=true`; do not remove it, or a Windows clone will check
   the shell scripts out with CRLF and every suite will fail on them.
5. **The effort ladder is `off | low | high | max`.** There is no `medium`; a profile
   that names one fails at runtime. Both test suites assert the ladder.
6. **Do not sync this kit into `C:\Users\THINKPAD X1\.agents\skills\dsh-orchestration\`.**
   The installed copy is deliberately left alone.
7. **Keep `.gitignore` honest:** `.test-install/` and `tests/.last-run.json` are
   scratch and must stay ignored.

## Environment constraints (Windows + the DSH sandbox)

- Run PowerShell scripts as
  `powershell -NoProfile -ExecutionPolicy Bypass -File <script>`; unsigned scripts
  are refused under the `RemoteSigned` policy.
- `Start-Process` with redirected output is denied by the sandbox. Invoke native
  children as `& $exe args 2>&1 | Out-File -LiteralPath $log -Encoding utf8` with
  `$ErrorActionPreference` temporarily `'Continue'`.
- No POSIX shell can start here: Git/MSYS bash dies with
  `couldn't create signal pipe, Win32 error 5`. Verify `setup.sh` through WSL
  instead, from an approved (unsandboxed) shell:
  `wsl -d Ubuntu -e bash /mnt/d/Web/dsh-orchestration/tests/wsl-run.sh`
  which reports the line endings of the source scripts, copies the kit to `/tmp`,
  and runs `tests/test_install.sh` there. The driver is committed
  (`tests/wsl-run.sh`) because the PowerShell suite wipes `.test-install/`
  wholesale - scratch is not a safe home for a tool you need afterwards.
- The WSL distro must be named: the default is `docker-desktop`, which has no bash.
- `git push` needs `$env:GIT_SSH = 'C:\Windows\System32\OpenSSH\ssh.exe'`; git's
  bundled Cygwin `ssh.exe` cannot start under the sandbox.
- Scratch directories stay inside the repository so each suite is self-contained and
  its debris is already gitignored (`.test-install/`). Do not move them to `%TEMP%`:
  a failed run there leaves files that no `.gitignore` covers.
- PowerShell 5.1 has no `<<<` and no heredoc. `git commit -F - <<< $msg` is a parse
  error that aborts the whole script, including any `git add` before it. Write the
  message to a temp file, then `git commit -F <file>`.

## The three suites

| Command | Checks | Covers |
| --- | --- | --- |
| `node tests/test_profiles.js` | 311 | Profile schema, embedded-table drift, one model on every tier, node order, model pins, prompt assembly, the summary/full evidence envelope, fan-out width vs cap, slice partitioning with its merge/refusal guard, failure degradation. |
| `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_install.ps1` | 83 | The PowerShell installer: file lists, byte-identical copies, idempotency, profile switch, component subsets, user scope, numerics, refusals. |
| `bash tests/test_install.sh` | 108 | The POSIX installer, mirroring the above, plus a pass with `python3` and `node` removed from `PATH`. Verified on Linux bash 5.3.9; macOS is unexercised. |

All three must stay green before a commit that touches the kit.
