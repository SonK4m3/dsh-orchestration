#!/usr/bin/env bash
#
# setup.sh - install the DSH orchestration kit into a project, or into $DSH_HOME.
#
# A mirror of setup.ps1 for macOS and Linux: same components, same destinations,
# same managed-region markers in AGENTS.md. The two installers are meant to
# produce the same AGENTS.md block and the same file layout.
#
#   ./setup.sh --list
#   ./setup.sh --target ~/code/my-app --profile pro
#   ./setup.sh --target ~/code/my-app --profile plus --components skill,AGENTS.md --yes
#   ./setup.sh --scope user --profile pro-exec-max --yes
#   ./setup.sh --target ~/code/my-app --dry-run
#
# Exit codes: 0 installed (or listed / dry run), 1 refused with a reason.
#
# Verified by tests/test_install.sh on Linux bash 5.3.9 (WSL Ubuntu): 108 checks,
# 0 failures, including a run with python3 and node removed from PATH so the sed
# profile reader is exercised too. macOS (bash 3.2, BSD userland) has NOT been
# exercised; that is why the script avoids bash 4+ syntax and uses POSIX sh
# constructs throughout. setup.ps1 remains the reference implementation, and the
# two installers must keep producing the same AGENTS.md block and file layout.

set -euo pipefail

KIT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE_ORDER=(pro plus pro-2-subagents plus-2-subagents pro-max pro-exec-max)
COMPONENT_NAMES=(skill orchestration AGENTS.md)
BEGIN_MARKER='<!-- dsh-orchestration:begin -->'
END_MARKER='<!-- dsh-orchestration:end -->'

TARGET=""
PROFILE=pro
SCOPE=project
COMPONENTS=""
ASSUME_YES=0
DRY_RUN=0
SHOW_LIST=0

usage() {
  cat <<'USAGE'
DSH orchestration kit - installer

  --target, -t DIR        project to install into (must exist)
  --profile, -p NAME|N    profile name, or its number from --list (default: pro)
  --scope, -s project|user  project (default) or $DSH_HOME
  --components, -c LIST   comma-separated subset of: skill,orchestration,AGENTS.md
  --yes, -y               do not ask for confirmation
  --dry-run, -n           print the plan, write nothing
  --list, -l              list the profiles and exit
  --help, -h              this text

  Components and their destinations (project scope):

    skill          <target>/.dsh/skills/dsh-orchestration/   SKILL.md + references + assets
    orchestration  <target>/.dsh/orchestration/              orchestrate.js + profile.json + README.md
    AGENTS.md      <target>/AGENTS.md                        merged, never clobbered

  With --scope user the destinations move under $DSH_HOME (default ~/.dsh):
  skills/, orchestration/, and the user-global AGENTS.md that DSH reads first.
USAGE
}

die() { printf '\nSetup cancelled: %s\n' "$*" >&2; exit 1; }
step() { printf '  %s\n' "$*"; }
heading() { printf '\n%s\n' "$*"; }

# --- profile data -------------------------------------------------------------

# json_field <profile.json> <dotted.path>
# Uses a real JSON parser when one is present, and falls back to reading the
# fixed layout this kit writes (root/execution/reviewer are single-line objects).
json_field() {
  local file="$1" path="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
sys.stdout.write(str(value))' "$file" "$path"
  elif command -v node >/dev/null 2>&1; then
    node -e 'const fs = require("fs")
let value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
for (const key of process.argv[2].split(".")) value = value[key]
process.stdout.write(String(value))' "$file" "$path"
  else
    case "$path" in
      name|displayName|description)
        sed -n "s/^  \"$path\": \"\(.*\)\",\{0,1\}$/\1/p" "$file" | head -n 1 ;;
      root.model|execution.model|reviewer.model)
        sed -n "s/^  \"${path%%.*}\": { \"model\": \"\([^\"]*\)\".*/\1/p" "$file" | head -n 1 ;;
      root.reasoning_effort|execution.reasoning_effort|reviewer.reasoning_effort)
        sed -n "s/^  \"${path%%.*}\": { \"model\": \"[^\"]*\", \"reasoning_effort\": \"\([^\"]*\)\".*/\1/p" "$file" | head -n 1 ;;
      host.maxActiveSubagents)
        sed -n 's/^    "maxActiveSubagents": \([0-9]*\),\{0,1\}$/\1/p' "$file" | head -n 1 ;;
      *) printf '' ;;
    esac
  fi
}

profile_file() { printf '%s' "$KIT_ROOT/profiles/$1/profile.json"; }

# require_field <profile.json> <dotted.path> - renders one field. Fields are
# validated up front by assert_profile_fields instead of dying here, because a
# die inside a command substitution only kills that subshell: the caller would
# carry on and write an empty value into AGENTS.md.
require_field() {
  json_field "$1" "$2"
}

assert_profile_fields() {
  local file="$1" field
  for field in name displayName description root.model root.reasoning_effort \
    execution.model execution.reasoning_effort reviewer.model \
    reviewer.reasoning_effort host.maxActiveSubagents; do
    if [ -z "$(json_field "$file" "$field")" ]; then
      die "could not read '$field' from $file: the profile layout changed, or no JSON parser is available (install node or python3)"
    fi
  done
}

list_profiles() {
  heading 'Available profiles'
  local index=1 name file
  for name in "${PROFILE_ORDER[@]}"; do
    file="$(profile_file "$name")"
    [ -f "$file" ] || continue
    printf '  %s  %-17s root %s/%s  exec %s/%s  review %s/%s  max %s\n' \
      "$index" "$name" \
      "$(json_field "$file" root.model)" "$(json_field "$file" root.reasoning_effort)" \
      "$(json_field "$file" execution.model)" "$(json_field "$file" execution.reasoning_effort)" \
      "$(json_field "$file" reviewer.model)" "$(json_field "$file" reviewer.reasoning_effort)" \
      "$(json_field "$file" host.maxActiveSubagents)"
    index=$((index + 1))
  done
  printf '\n'
}

# --- arguments ----------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --target|-t)      [ $# -ge 2 ] || die 'option --target needs a value'; TARGET="$2"; shift 2 ;;
    --profile|-p)     [ $# -ge 2 ] || die 'option --profile needs a value'; PROFILE="$2"; shift 2 ;;
    --scope|-s)       [ $# -ge 2 ] || die 'option --scope needs a value'; SCOPE="$2"; shift 2 ;;
    --components|-c)  [ $# -ge 2 ] || die 'option --components needs a value'; COMPONENTS="$2"; shift 2 ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --dry-run|-n)     DRY_RUN=1; shift ;;
    --list|-l)        SHOW_LIST=1; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) die "unknown option '$1' (try --help)" ;;
  esac
done

# --- helpers ------------------------------------------------------------------

confirm() {
  local name="$1" detail="$2"
  [ "$ASSUME_YES" = 1 ] && return 0
  printf 'Install %s (%s)? [Y/n] ' "$name" "$detail"
  local answer=''
  read -r answer || true
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ -z "$answer" ] && return 0
  [ "$answer" = y ] || [ "$answer" = yes ]
}

is_reparse_point() {
  [ -L "$1" ]
}

# prints the destination-relative paths a component will write
planned_paths() {
  case "$1" in
    skill)
      printf '%s\n' 'SKILL.md'
      ( cd "$KIT_ROOT" && find references assets -type f 2>/dev/null ) | sed 's|^\./||'
      ;;
    orchestration) printf '%s\n' 'orchestrate.js' 'profile.json' 'README.md' ;;
    AGENTS.md)     printf '%s\n' 'AGENTS.md' ;;
  esac
}

warn_overwrites() {
  local component="$1" dest="$2"
  local existing=()
  local relative
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    if [ -e "$dest/$relative" ]; then existing+=("$relative"); fi
  done < <(planned_paths "$component")
  if [ "${#existing[@]}" -gt 0 ]; then
    printf '\n  WARNING: %s existing file(s) under %s will be overwritten:\n' "${#existing[@]}" "$dest"
    for relative in "${existing[@]}"; do step "  $relative"; done
  fi
  return 0
}

# --- components ---------------------------------------------------------------

install_skill() {
  local dest="$1"
  local item
  for item in SKILL.md references assets; do
    [ -e "$KIT_ROOT/$item" ] || die "kit is incomplete: $KIT_ROOT/$item is missing"
  done
  if is_reparse_point "$dest"; then die "refusing to write through a symlink at $dest"; fi
  if [ "$DRY_RUN" = 1 ]; then
    step "would create $dest"
    planned_paths skill | while IFS= read -r relative; do step "would write $relative"; done
    return 0
  fi
  [ -d "$dest" ] || mkdir -p "$dest"
  # "src/." copies the directory *contents* into an existing directory, so a
  # re-install merges instead of nesting references/references.
  mkdir -p "$dest/references" "$dest/assets"
  cp "$KIT_ROOT/SKILL.md" "$dest/SKILL.md"
  cp -R "$KIT_ROOT/references/." "$dest/references/"
  cp -R "$KIT_ROOT/assets/." "$dest/assets/"
}

orchestration_note() {
  local name="$1" file="$2"
  printf '# Orchestration profile: %s\n\n' "$name"
  printf '%s\n\n' "$(json_field "$file" description)"
  printf 'Use `orchestrate.js` by pasting it into the `workflow` tool'"'"'s `script` argument, with args:\n\n'
  printf '    { objective: "...", profile: "%s", requirements: [...], writePaths: "..." }\n\n' "$name"
  printf 'The profile records which model and requested effort each node runs at. The script pins the\n'
  printf 'model per node; reasoning effort is a request written into the prompt, because the workflow\n'
  printf 'tool exposes no effort override.\n\n'
  printf 'Reasoning effort values DSH accepts: off | low | high | max (default high).\n'
}

install_orchestration() {
  local dest="$1" name="$2" file="$3"
  [ -f "$KIT_ROOT/scripts/orchestrate.js" ] || die "kit is incomplete: $KIT_ROOT/scripts/orchestrate.js is missing"
  if is_reparse_point "$dest"; then die "refusing to write through a symlink at $dest"; fi
  if [ "$DRY_RUN" = 1 ]; then
    step "would create $dest"
    step 'would write orchestrate.js'
    step "would write profile.json ($name)"
    step 'would write README.md'
    return 0
  fi
  [ -d "$dest" ] || mkdir -p "$dest"
  cp "$KIT_ROOT/scripts/orchestrate.js" "$dest/orchestrate.js"
  cp "$file" "$dest/profile.json"
  orchestration_note "$name" "$file" > "$dest/README.md"
}

profile_section() {
  local file="$1"
  printf '## Profile in use\n\n'
  printf 'Profile: `%s` - %s\n\n' "$(require_field "$file" name)" "$(require_field "$file" displayName)"
  printf '| Node | Model | Requested effort | Access |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '| root (you) | %s | %s | orchestrates and integrates |\n' \
    "$(require_field "$file" root.model)" "$(require_field "$file" root.reasoning_effort)"
  printf '| explorer, researcher, worker, tester | %s | %s | read-only, write, test artifacts |\n' \
    "$(require_field "$file" execution.model)" "$(require_field "$file" execution.reasoning_effort)"
  printf '| reviewer | %s | %s | read-only |\n\n' \
    "$(require_field "$file" reviewer.model)" "$(require_field "$file" reviewer.reasoning_effort)"
  printf 'Concurrency: keep at most %s subagents alive (Host setting `maxActiveSubagents`).' \
    "$(require_field "$file" host.maxActiveSubagents)"
}

build_agents_block() {
  local file="$1" out="$2"
  local body
  body="$(cat "$KIT_ROOT/assets/agents-block.md")"
  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '%s' "$body"
    printf '\n\n'
    profile_section "$file"
    printf '\n%s\n' "$END_MARKER"
  } > "$out"
}

install_agents_block() {
  local dest="$1" file="$2"
  local stage="${dest}.dsh-orchestration.tmp"
  build_agents_block "$file" "$stage"

  if [ "$DRY_RUN" = 1 ]; then
    if [ -f "$dest" ]; then step "would merge the dsh-orchestration block into $dest"; else step "would create $dest"; fi
    rm -f "$stage"
    printf 'dry-run\n'
    return 0
  fi

  if is_reparse_point "$dest"; then
    rm -f "$stage"
    die "refusing to write through a symlink at $dest"
  fi

  if [ ! -f "$dest" ]; then
    mv "$stage" "$dest"
    printf 'created\n'
    return 0
  fi

  local begin_line end_line tmp
  begin_line="$(grep -nF "$BEGIN_MARKER" "$dest" | head -n 1 | cut -d: -f1 || true)"
  end_line="$(grep -nF "$END_MARKER" "$dest" | head -n 1 | cut -d: -f1 || true)"
  tmp="${dest}.dsh-orchestration.merged"

  if [ -n "$begin_line" ] && [ -n "$end_line" ] && [ "$end_line" -gt "$begin_line" ]; then
    {
      head -n $((begin_line - 1)) "$dest"
      cat "$stage"
      tail -n +$((end_line + 1)) "$dest"
    } > "$tmp"
  elif [ -n "$begin_line" ]; then
    rm -f "$stage" "$tmp"
    die "AGENTS.md has a dsh-orchestration begin marker with no end marker: $dest"
  else
    {
      cat "$dest"
      printf '\n'
      cat "$stage"
    } > "$tmp"
  fi

  if cmp -s "$dest" "$tmp"; then
    rm -f "$stage" "$tmp"
    printf 'already-present\n'
  else
    mv "$tmp" "$dest"
    rm -f "$stage"
    printf 'updated\n'
  fi
}

# --- main ---------------------------------------------------------------------

[ -d "$KIT_ROOT/profiles" ] || die "profiles directory not found at $KIT_ROOT/profiles"

printf '\n  DSH orchestration kit - installer\n'
printf '  Astra/Luna two-tier topology for DeepSeek Harness\n'

if [ "$SHOW_LIST" = 1 ]; then
  list_profiles
  exit 0
fi

case "$PROFILE" in
  ''|*[!0-9]*) ;;
  *)
    [ "$PROFILE" -ge 1 ] && [ "$PROFILE" -le "${#PROFILE_ORDER[@]}" ] \
      || die "profile number must be between 1 and ${#PROFILE_ORDER[@]}"
    PROFILE="${PROFILE_ORDER[$((PROFILE - 1))]}"
    ;;
esac

SELECTED="$(profile_file "$PROFILE")"
[ -f "$SELECTED" ] || die "unknown profile '$PROFILE'. Available: $(printf '%s, ' "${PROFILE_ORDER[@]}" | sed 's/, $//')"

case "$SCOPE" in
  project|user) ;;
  *) die "unknown scope '$SCOPE'. Available: project, user" ;;
esac

if [ -z "$COMPONENTS" ]; then
  component_list=("${COMPONENT_NAMES[@]}")
else
  IFS=',' read -r -a component_list <<< "$COMPONENTS"
fi
for component in "${component_list[@]}"; do
  match=0
  for known in "${COMPONENT_NAMES[@]}"; do
    if [ "$component" = "$known" ]; then match=1; break; fi
  done
  [ "$match" = 1 ] || die "unknown component '$component'. Available: $(printf '%s, ' "${COMPONENT_NAMES[@]}" | sed 's/, $//')"
done

# Only the components that render the profile need it to be readable; a
# skill-only install must still work if a profile file is unreadable.
needs_profile=0
for component in "${component_list[@]}"; do
  case "$component" in
    orchestration|AGENTS.md) needs_profile=1 ;;
  esac
done
[ "$needs_profile" = 0 ] || assert_profile_fields "$SELECTED"

if [ "$SCOPE" = user ]; then
  SCOPE_ROOT="${DSH_HOME:-}"
  if [ -z "$SCOPE_ROOT" ]; then
    [ -n "${HOME:-}" ] || die 'neither DSH_HOME nor HOME is set; pass DSH_HOME=<dir> with --scope user'
    SCOPE_ROOT="$HOME/.dsh"
  fi
  [ "$DRY_RUN" = 1 ] || mkdir -p "$SCOPE_ROOT"
  SKILL_DEST="$SCOPE_ROOT/skills/dsh-orchestration"
  ORCHESTRATION_DEST="$SCOPE_ROOT/orchestration"
  AGENTS_DEST="$SCOPE_ROOT/AGENTS.md"
else
  if [ -z "$TARGET" ]; then
    if [ "$ASSUME_YES" = 1 ]; then die 'Target is required when --yes is used (or pass --scope user).'; fi
    printf 'Target repository path: '
    read -r TARGET || die 'no target given'
  fi
  [ -d "$TARGET" ] || die "target is not a directory: $TARGET"
  SCOPE_ROOT="$(cd -- "$TARGET" && pwd -P)"
  if [ "$SCOPE_ROOT" = "$KIT_ROOT" ]; then die 'target must not be the kit directory itself; choose the project you are installing into'; fi
  SKILL_DEST="$SCOPE_ROOT/.dsh/skills/dsh-orchestration"
  ORCHESTRATION_DEST="$SCOPE_ROOT/.dsh/orchestration"
  AGENTS_DEST="$SCOPE_ROOT/AGENTS.md"
fi

heading "Scope:    $SCOPE ($SCOPE_ROOT)"
heading "Profile:  $PROFILE"
step "skill          -> $SKILL_DEST"
step "orchestration  -> $ORCHESTRATION_DEST"
step "AGENTS.md      -> $AGENTS_DEST"
if [ "$DRY_RUN" = 1 ]; then printf '\n  Dry run: nothing will be written.\n'; fi

results=()

for component in "${component_list[@]}"; do
  case "$component" in
    skill)
      warn_overwrites skill "$SKILL_DEST"
      if confirm skill 'SKILL.md, references, assets'; then
        install_skill "$SKILL_DEST"
        results+=("skill: installed")
      else
        results+=('skill: skipped')
      fi
      ;;
    orchestration)
      warn_overwrites orchestration "$ORCHESTRATION_DEST"
      if confirm orchestration 'orchestrate.js + the selected profile'; then
        install_orchestration "$ORCHESTRATION_DEST" "$PROFILE" "$SELECTED"
        results+=("orchestration: installed ($PROFILE)")
      else
        results+=('orchestration: skipped')
      fi
      ;;
    AGENTS.md)
      if confirm 'AGENTS.md' 'merge into instructions DSH reads'; then
        results+=("AGENTS.md: $(install_agents_block "$AGENTS_DEST" "$SELECTED")")
      else
        results+=('AGENTS.md: skipped')
      fi
      ;;
  esac
done

heading 'Summary'
if [ "${#results[@]}" -gt 0 ]; then
  for line in "${results[@]}"; do step "$line"; done
fi

heading 'Two Host settings this kit depends on'
step '1. Enable subagent model selection so a subagent can be pinned to a model.'
step '   Without it, model pins only apply through the workflow tool (which always supports them).'
step "2. If you use profile $PROFILE, set maxActiveSubagents to $(require_field "$SELECTED" host.maxActiveSubagents)."
step '   Open the DSH settings panel to change both; no file in this repo controls them.'

heading 'Next'
step 'Restart the session if the skill does not appear: DSH discovers skills at <project>/.dsh/skills.'
if [ "$DRY_RUN" = 1 ]; then
  printf '\n  Dry run complete: nothing was written.\n'
else
  printf '\n  Installed.\n'
fi
exit 0
