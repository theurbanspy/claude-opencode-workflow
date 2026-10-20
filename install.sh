#!/usr/bin/env bash
# Installs the oc-plan / oc-execute skills and the oc-worker launcher into ~/.claude
# (or $CLAUDE_HOME). Never touches OpenCode config or credentials.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDE_HOME:-$HOME/.claude}"
STAMP="$(date +%Y%m%d%H%M%S)"

for cmd in opencode jq perl python3 git; do
  command -v "$cmd" >/dev/null 2>&1 || echo "warning: '$cmd' not found in PATH (needed at run time)"
done

install_dir() {
  local from="$1" to="$2"
  mkdir -p "$(dirname "$to")"
  if [ -e "$to" ]; then
    mv "$to" "$to.bak-$STAMP"
    echo "existing $to moved to $to.bak-$STAMP"
  fi
  cp -R "$from" "$to"
  echo "installed $to"
}

install_dir "$SRC/skills/oc-plan"    "$DEST/skills/oc-plan"
install_dir "$SRC/skills/oc-execute" "$DEST/skills/oc-execute"
install_dir "$SRC/oc-worker"         "$DEST/oc-worker"

find "$DEST/skills/oc-plan" "$DEST/skills/oc-execute" "$DEST/oc-worker" \
  \( -name '*.sh' -o -name '*.py' -o -name 'opencode-stub' \) -exec chmod +x {} +

cat <<EOM

Done. Next steps:
  1. Log in to OpenCode in a terminal (never paste a key into a chat):
       opencode auth login opencode
  2. Check the install (offline run is free; --live uses a few requests of quota):
       bash $DEST/oc-worker/test/selftest.sh --live
EOM
