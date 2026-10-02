#!/usr/bin/env bash
#
# tests/test_install.sh - functional tests for setup.sh.
#
#   bash tests/test_install.sh
#
# Mirrors tests/test_install.ps1 section for section. Everything is written under
# a scratch directory in ${TMPDIR:-/tmp}; the kit itself is never modified.
# Exit code 0 means every check passed.

set -uo pipefail

KIT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SETUP="$KIT_ROOT/setup.sh"
SCRATCH_ROOT="${TMPDIR:-/tmp}/dsh-orchestration-test.$$"
BEGIN_MARKER='<!-- dsh-orchestration:begin -->'
END_MARKER='<!-- dsh-orchestration:end -->'

OUT="$SCRATCH_ROOT/stdout"
ERR="$SCRATCH_ROOT/stderr"
RC=0
PASS=0
FAIL=0
SKIP=0

cleanup() { rm -rf "$SCRATCH_ROOT"; }
trap cleanup EXIT

rm -rf "$SCRATCH_ROOT"
mkdir -p "$SCRATCH_ROOT"

section() { printf '\n== %s\n' "$1"; }
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '        %s\n' "$2"; fi
}
skipped() { SKIP=$((SKIP + 1)); printf '  SKIP  %s (%s)\n' "$1" "$2"; }

assert() { # assert <label> <command...>
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label" "false: $*"; fi
}
assert_not() { # assert_not <label> <command...>
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$label" "should not hold: $*"; else ok "$label"; fi
}
assert_eq() { # assert_eq <label> <expected> <actual>
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$label"
  else
    bad "$label" "expected [$expected], got [$actual]"
  fi
}
assert_rc() { # assert_rc <label> <expected exit code>
  local label="$1" expected="$2"
  if [ "$RC" = "$expected" ]; then
    ok "$label"
  else
    bad "$label" "exit $RC, expected $expected; stderr: $(head -c 300 "$ERR" | tr '\n' ' ')"
  fi
}
assert_refused() { # assert_refused <label> <stderr fragment>
  local label="$1" fragment="$2"
  if [ "$RC" = 1 ] && grep -qF -- "$fragment" "$ERR"; then
    ok "$label"
  else
    bad "$label" "exit $RC with [$fragment] missing; stderr: $(head -c 300 "$ERR" | tr '\n' ' ')"
  fi
}
assert_contains() { # assert_contains <label> <file> <needle>
  local label="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then ok "$label"; else bad "$label" "[$needle] not found in $file"; fi
}
assert_same_file() { # assert_same_file <label> <a> <b>
  local label="$1" a="$2" b="$3"
  if cmp -s "$a" "$b"; then ok "$label"; else bad "$label" "$a and $b differ"; fi
}

capture() { # run a command with stdin closed, recording stdout, stderr and status
  "$@" >"$OUT" 2>"$ERR" </dev/null
  RC=$?
}
run_setup() { capture "$BASH" "$SETUP" "$@"; }
run_setup_path() { # run_setup_path <PATH> <args...>
  local path="$1"
  shift
  capture env PATH="$path" "$BASH" "$SETUP" "$@"
}

fresh_target() { # fresh_target <name>
  local dir="$SCRATCH_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s' "$dir"
}
kit_skill_files() { ( cd "$KIT_ROOT" && find SKILL.md references assets -type f | LC_ALL=C sort ); }
installed_files() { ( cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ); }

# Counts bytes that no shell script should carry: anything outside tab plus
# printable ASCII. This also catches CR, which would break bash on macOS/Linux.
bad_bytes() {
  LC_ALL=C awk '
    { for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c != "\t" && (c < " " || c > "~")) n++ } }
    END { print n + 0 }
  ' "$1"
}

build_shim() { # a PATH with the kit's tools but deliberately no JSON parser
  local shim="$SCRATCH_ROOT/shim" cmd src
  mkdir -p "$shim"
  for cmd in sed awk grep cp cmp mkdir find head tail cut tr mv rm cat dirname basename pwd ls env bash sh; do
    src="$(command -v "$cmd" 2>/dev/null)" || continue
    ln -sf "$src" "$shim/$cmd"
  done
  printf '%s' "$shim"
}

SYMLINKS=1
ln -s /nonexistent-target "$SCRATCH_ROOT/probe.link" 2>/dev/null || true
if [ ! -L "$SCRATCH_ROOT/probe.link" ]; then SYMLINKS=0; fi
rm -f "$SCRATCH_ROOT/probe.link"

printf '\nDSH orchestration kit - setup.sh tests\n'
printf '  bash %s\n' "${BASH_VERSION:-unknown}"
printf '  kit  %s\n' "$KIT_ROOT"
printf '  tmp  %s\n' "$SCRATCH_ROOT"

# ------------------------------------------------------------------------------
section '0. source hygiene'
assert_eq 'setup.sh is pure ASCII with LF endings' 0 "$(bad_bytes "$SETUP")"
assert_eq 'tests/test_install.sh is pure ASCII with LF endings' 0 "$(bad_bytes "$KIT_ROOT/tests/test_install.sh")"
assert 'setup.sh starts with a bash shebang' grep -q '^#!/usr/bin/env bash$' "$SETUP"
assert 'setup.sh is executable or at least runnable by bash' test -r "$SETUP"

# ------------------------------------------------------------------------------
section '1. --list'
run_setup --list
assert_rc '--list exits 0' 0
assert_eq '--list prints one row per profile' 6 "$(grep -cE '^  [1-9]  ' "$OUT")"
for name in pro plus pro-2-subagents plus-2-subagents pro-max pro-exec-max; do
  assert_contains "lists $name" "$OUT" "$name"
done
assert_contains 'shows the strong root pin' "$OUT" 'deepseek-v4-pro/high'
assert_contains 'shows the max-effort execution pin' "$OUT" 'exec deepseek-flash/max'

# ------------------------------------------------------------------------------
section '2. --dry-run writes nothing'
t="$(fresh_target dry)"
run_setup --target "$t" --profile pro --yes --dry-run
assert_rc 'dry run exits 0' 0
assert_contains 'dry run says nothing will be written' "$OUT" 'Dry run'
assert_contains 'dry run reports the skill destination' "$OUT" 'dsh-orchestration'
assert_not 'dry run created no .dsh' test -e "$t/.dsh"
assert_not 'dry run created no AGENTS.md' test -e "$t/AGENTS.md"

# ------------------------------------------------------------------------------
section '3. full project install'
t="$(fresh_target full)"
printf '# Project rules\n\nKeep this line.\n' > "$t/AGENTS.md"
run_setup --target "$t" --profile plus-2-subagents --yes
assert_rc 'install exits 0' 0
skill_dest="$t/.dsh/skills/dsh-orchestration"
assert_same_file 'SKILL.md installed' "$KIT_ROOT/SKILL.md" "$skill_dest/SKILL.md"
assert_eq 'skill bundle is exactly SKILL.md + references + assets' "$(kit_skill_files)" "$(installed_files "$skill_dest")"
for forbidden in tests scripts profiles setup.ps1 setup.sh README.md .git orchestrate.js profile.json; do
  assert_not "skill dir contains no $forbidden" test -e "$skill_dest/$forbidden"
done
assert_same_file 'orchestrate.js is byte-identical' "$KIT_ROOT/scripts/orchestrate.js" "$t/.dsh/orchestration/orchestrate.js"
assert_same_file 'profile.json is the selected profile' "$KIT_ROOT/profiles/plus-2-subagents/profile.json" "$t/.dsh/orchestration/profile.json"
assert 'orchestration README written' test -f "$t/.dsh/orchestration/README.md"
assert_contains 'README names the profile' "$t/.dsh/orchestration/README.md" 'plus-2-subagents'
assert_contains 'README names the effort ladder' "$t/.dsh/orchestration/README.md" 'off | low | high | max'
assert_contains 'AGENTS.md has the begin marker' "$t/AGENTS.md" "$BEGIN_MARKER"
assert_contains 'AGENTS.md has the end marker' "$t/AGENTS.md" "$END_MARKER"
assert_contains 'AGENTS.md keeps existing content' "$t/AGENTS.md" 'Keep this line.'
assert_contains 'AGENTS.md records the profile' "$t/AGENTS.md" 'Profile: `plus-2-subagents`'
assert_contains 'AGENTS.md records the model pin' "$t/AGENTS.md" 'deepseek-flash'
assert_contains 'AGENTS.md records concurrency' "$t/AGENTS.md" 'at most 2 subagents'
assert_contains 'summary reports the skill' "$OUT" 'skill: installed'
assert_contains 'summary reports the profile' "$OUT" 'orchestration: installed (plus-2-subagents)'
assert_contains 'summary reports AGENTS.md created' "$OUT" 'AGENTS.md: updated'

# ------------------------------------------------------------------------------
section '4. re-run is idempotent'
cp "$t/AGENTS.md" "$SCRATCH_ROOT/agents-before.md"
before_hash="$(cksum "$t/AGENTS.md")"
run_setup --target "$t" --profile plus-2-subagents --yes
assert_rc 'second run exits 0' 0
assert_same_file 'AGENTS.md is byte-identical' "$SCRATCH_ROOT/agents-before.md" "$t/AGENTS.md"
assert_eq 'AGENTS.md checksum stable' "$before_hash" "$(cksum "$t/AGENTS.md")"
assert_contains 'reported as already-present' "$OUT" 'AGENTS.md: already-present'
assert_contains 'warned about the overwrite' "$OUT" 'will be overwritten'
assert_eq 'no nested references directory' '' "$(find "$skill_dest" -type d -name references -mindepth 2 2>/dev/null)"

# ------------------------------------------------------------------------------
section '5. profile switch rewrites only the managed region'
run_setup --target "$t" --profile pro-max --yes
assert_rc 'switch exits 0' 0
assert_contains 'new profile recorded' "$t/AGENTS.md" 'Profile: `pro-max`'
assert_eq 'old profile removed from the block' 0 "$(grep -c 'plus-2-subagents' "$t/AGENTS.md")"
assert_contains 'surrounding content preserved' "$t/AGENTS.md" 'Keep this line.'
assert_eq 'first line preserved' '# Project rules' "$(head -n 1 "$t/AGENTS.md")"
assert_eq 'exactly one begin marker' 1 "$(grep -cF "$BEGIN_MARKER" "$t/AGENTS.md")"
assert_eq 'exactly one end marker' 1 "$(grep -cF "$END_MARKER" "$t/AGENTS.md")"
assert_contains 'summary reports the switch' "$OUT" 'orchestration: installed (pro-max)'

# ------------------------------------------------------------------------------
section '6. component subsets'
t="$(fresh_target subset-skill)"
run_setup --target "$t" --components skill --yes
assert_rc 'skill-only install exits 0' 0
assert 'skill written' test -f "$t/.dsh/skills/dsh-orchestration/SKILL.md"
assert_not 'orchestration skipped' test -e "$t/.dsh/orchestration"
assert_not 'AGENTS.md skipped' test -e "$t/AGENTS.md"
t="$(fresh_target subset-orch)"
run_setup --target "$t" -c orchestration -y
assert_rc 'orchestration-only install exits 0' 0
assert 'orchestration written' test -f "$t/.dsh/orchestration/orchestrate.js"
assert_not 'skill skipped' test -e "$t/.dsh/skills"
assert_not 'AGENTS.md skipped' test -e "$t/AGENTS.md"
t="$(fresh_target subset-agents)"
run_setup --target "$t" -c AGENTS.md -y
assert_rc 'AGENTS.md-only install exits 0' 0
assert 'AGENTS.md written' test -f "$t/AGENTS.md"
assert_not 'no .dsh directory created' test -e "$t/.dsh"

# ------------------------------------------------------------------------------
section '7. numeric profile selection'
t="$(fresh_target numeric)"
run_setup -t "$t" -p 3 -y
assert_rc 'numeric profile exits 0' 0
assert_contains 'third profile is pro-2-subagents' "$t/.dsh/orchestration/profile.json" '"name": "pro-2-subagents"'
assert_contains 'summary confirms pro-2-subagents' "$OUT" 'orchestration: installed (pro-2-subagents)'

# ------------------------------------------------------------------------------
section '8. --scope user'
home="$SCRATCH_ROOT/home"
capture env DSH_HOME="$home" "$BASH" "$SETUP" --scope user --profile pro --yes
assert_rc 'user scope exits 0' 0
assert 'user skill installed' test -f "$home/skills/dsh-orchestration/SKILL.md"
assert 'user orchestration installed' test -f "$home/orchestration/orchestrate.js"
assert 'user AGENTS.md written' test -f "$home/AGENTS.md"
assert_contains 'user AGENTS.md records the profile' "$home/AGENTS.md" 'Profile: `pro`'
assert_same_file 'user profile.json is the selected profile' "$KIT_ROOT/profiles/pro/profile.json" "$home/orchestration/profile.json"

# ------------------------------------------------------------------------------
section '9. refusals'
t="$(fresh_target refusals)"
run_setup -t "$t" -p does-not-exist -y
assert_refused 'unknown profile' 'unknown profile'
run_setup -t "$t" -c does-not-exist -y
assert_refused 'unknown component' 'unknown component'
run_setup -t "$t" -s elsewhere -y
assert_refused 'unknown scope' 'unknown scope'
run_setup -t "$KIT_ROOT" -y
assert_refused 'kit root as target' 'target must not be the kit directory itself'
run_setup -t "$SCRATCH_ROOT/no-such-dir" -y
assert_refused 'missing target' 'target is not a directory'
printf 'x\n' > "$SCRATCH_ROOT/a-file"
run_setup -t "$SCRATCH_ROOT/a-file" -y
assert_refused 'file as target' 'target is not a directory'
run_setup -y
assert_refused '--yes with no target' 'Target is required when --yes is used'
run_setup -t "$t" --bogus
assert_refused 'unknown option' "unknown option '--bogus'"
run_setup -t "$t" -p 9 -y
assert_refused 'profile number out of range' 'profile number must be between 1 and 6'
printf '# t\n%s\n' "$BEGIN_MARKER" > "$t/AGENTS.md"
run_setup -t "$t" -c AGENTS.md -y
assert_refused 'unterminated marker block' 'begin marker with no end marker'
assert_contains 'unterminated block left the file alone' "$t/AGENTS.md" "$BEGIN_MARKER"
rm -f "$t/AGENTS.md"
assert_not 'no refusal wrote anything' test -e "$t/.dsh"
if [ "$SYMLINKS" = 1 ]; then
  printf '# real file\n' > "$SCRATCH_ROOT/real-agents.md"
  ln -s "$SCRATCH_ROOT/real-agents.md" "$t/AGENTS.md"
  run_setup -t "$t" -c AGENTS.md -y
  assert_refused 'symlinked AGENTS.md' 'refusing to write through a symlink'
  assert_eq 'the symlink target was not written' '# real file' "$(head -n 1 "$SCRATCH_ROOT/real-agents.md")"
  rm -f "$t/AGENTS.md"
else
  skipped 'symlinked AGENTS.md refusal' 'this filesystem does not support symlinks'
fi

# ------------------------------------------------------------------------------
section '10. works without python3 or node'
if command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1; then
  shim="$(build_shim)"
  run_setup_path "$shim" --list
  assert_rc '--list exits 0 without a JSON parser' 0
  assert_contains 'fallback lists every profile' "$OUT" 'pro-exec-max'
  assert_contains 'fallback reads the model pin' "$OUT" 'deepseek-v4-pro/high'
  assert_contains 'fallback reads the execution effort' "$OUT" 'deepseek-flash/max'
  a="$(fresh_target parser-default)"
  b="$(fresh_target parser-fallback)"
  run_setup -t "$a" -p pro-exec-max -y
  assert_rc 'reference install exits 0' 0
  run_setup_path "$shim" -t "$b" -p pro-exec-max -y
  assert_rc 'fallback install exits 0' 0
  assert_same_file 'fallback AGENTS.md identical to the parser run' "$a/AGENTS.md" "$b/AGENTS.md"
  assert_same_file 'fallback profile.json identical' "$a/.dsh/orchestration/profile.json" "$b/.dsh/orchestration/profile.json"
  assert_same_file 'fallback orchestrate.js identical' "$a/.dsh/orchestration/orchestrate.js" "$b/.dsh/orchestration/orchestrate.js"
else
  skipped 'JSON fallback' 'no python3 or node available for a reference run'
fi

# ------------------------------------------------------------------------------
section '11. interactive confirmation'
t="$(fresh_target interactive)"
printf 'n\nn\nn\n' > "$SCRATCH_ROOT/answers"
"$BASH" "$SETUP" -t "$t" >"$OUT" 2>"$ERR" < "$SCRATCH_ROOT/answers"
RC=$?
assert_rc 'declining every component exits 0' 0
assert_contains 'skill reported skipped' "$OUT" 'skill: skipped'
assert_contains 'orchestration reported skipped' "$OUT" 'orchestration: skipped'
assert_contains 'AGENTS.md reported skipped' "$OUT" 'AGENTS.md: skipped'
assert_not 'nothing was written' test -e "$t/.dsh"
assert_not 'no AGENTS.md was written' test -e "$t/AGENTS.md"

# ------------------------------------------------------------------------------
printf '\n%s\n' '----------------------------------------------------------------------'
printf 'PASS %s   FAIL %s   SKIP %s\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" != 0 ]; then exit 1; fi
exit 0
