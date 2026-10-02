#!/usr/bin/env bash
#
# wsl-run.sh - run tests/test_install.sh against a copy of the kit.
#
# Why a copy: the suite installs into scratch directories, so it must see the kit
# exactly as a user receives it, and a stray file in the working tree must not be
# able to change what it verifies.
#
# Why this exists at all: on Windows there is no POSIX shell in which to run
# setup.sh. Git/MSYS bash cannot start under the DSH file sandbox (its signal pipe
# is a named pipe, and named pipes are blocked), so the POSIX suite is run through
# WSL, whose own /tmp and bash are unaffected by that sandbox:
#
#   wsl -d Ubuntu -e bash /mnt/d/Web/dsh-orchestration/tests/wsl-run.sh
#
# The line-ending report below runs on the SOURCE files, before anything is copied,
# so a CRLF regression is visible as soon as it happens rather than masked by the
# copy.

set -uo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DST="${TMPDIR:-/tmp}/dsh-kit-wsl-run"

echo "---- line endings on the source files ----"
for file in setup.sh tests/test_install.sh setup.ps1 tests/test_install.ps1; do
  if [ ! -f "$SRC/$file" ]; then
    printf '  MISSING  %s\n' "$file"
  elif LC_ALL=C tr -d '\r' < "$SRC/$file" | cmp -s - "$SRC/$file"; then
    printf '  LF       %s\n' "$file"
  else
    printf '  CRLF     %s\n' "$file"
  fi
done

rm -rf "$DST"
mkdir -p "$DST"
cp -R "$SRC/." "$DST/"
rm -rf "$DST/.git" "$DST/.test-install"

echo "kit copied: $SRC -> $DST"
echo "bash: $(bash --version | head -n 1)"
if command -v python3 >/dev/null 2>&1; then
  echo "python3: $(command -v python3)"
else
  echo "python3: none"
fi
if command -v node >/dev/null 2>&1; then
  echo "node: $(command -v node)"
else
  echo "node: none"
fi

echo "---- running tests/test_install.sh ----"
bash "$DST/tests/test_install.sh"
rc=$?
echo "---- test exit code: $rc ----"
exit "$rc"
