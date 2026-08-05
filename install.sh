#!/usr/bin/env bash
# Install claude-acct into ~/.claude and wire it into your shell.
#
#   ./install.sh              symlink from this repo (edits here take effect at once)
#   ./install.sh --copy       copy the files instead
#   ./install.sh --rc FILE    use a specific shell rc instead of guessing
#   ./install.sh --no-rc      install the files only, don't touch any rc file
#   ./install.sh --uninstall  remove what this installed (never touches accounts/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BIN="$CLAUDE_DIR/bin/claude-acct"
GLUE="$CLAUDE_DIR/claude-acct.sh"
LEGACY_GLUE="$CLAUDE_DIR/account-switcher.sh"

MODE="link"
RC=""
NO_RC=0
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE=copy ;;
    --rc) RC="${2:?--rc needs a file}"; shift ;;
    --no-rc) NO_RC=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || {
  echo "claude-acct needs python3 on your PATH." >&2; exit 1; }

# Guess the rc file. bash on macOS reads .bash_profile for login shells, which
# is what Terminal.app starts, so prefer that when it already exists.
if [ -z "$RC" ]; then
  case "${SHELL:-}" in
    */zsh)  RC="${ZDOTDIR:-$HOME}/.zshrc" ;;
    */fish) RC="" ;;
    */bash)
      if [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/.bash_profile" ]; then
        RC="$HOME/.bash_profile"
      else
        RC="$HOME/.bashrc"
      fi ;;
    *) RC="$HOME/.profile" ;;
  esac
fi
if [ -z "$RC" ] && [ "$NO_RC" = 0 ]; then
  echo "note: ${SHELL:-your shell} isn't a POSIX shell I can wire up automatically." >&2
  echo "      Add $CLAUDE_DIR/bin to your PATH by hand; everything else is optional." >&2
  NO_RC=1
fi

SOURCE_LINE='[ -f "$HOME/.claude/claude-acct.sh" ] && source "$HOME/.claude/claude-acct.sh"'

# Line edits go through python, not sed: the source line contains `&&`, and `&`
# in a sed replacement means "the whole match" — which silently duplicates the
# line it was meant to replace. (BSD and GNU sed also disagree on -i.)
rc_edit() {  # rc_edit <rc file> <drop|replace> <line>
  python3 - "$@" <<'PY'
import shutil, sys
rc, mode, line = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    src = open(rc).read().splitlines()
except FileNotFoundError:
    src = []
def hit(s):
    if "claude-acct.sh" in s or "account-switcher.sh" in s:
        return True
    return mode == "drop" and s.strip().startswith("# claude-acct")

out, replaced = [], False
for s in src:
    if not hit(s):
        out.append(s)
    elif mode == "replace" and not replaced:
        out.append(line)
        replaced = True
while out and not out[-1].strip():
    out.pop()
if src:
    shutil.copy2(rc, rc + ".pre-claude-acct.bak")
open(rc, "w").write("\n".join(out) + "\n")
print("replaced" if replaced else "dropped")
PY
}

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$BIN" "$GLUE"
  if [ "$NO_RC" = 0 ] && [ -f "$RC" ] && grep -q -e 'claude-acct.sh' -e 'account-switcher.sh' "$RC"; then
    rc_edit "$RC" drop "" >/dev/null
    echo "cleaned $RC (backup at $RC.pre-claude-acct.bak)"
  fi
  echo "uninstalled. Your saved accounts in $CLAUDE_DIR/accounts are untouched."
  exit 0
fi

mkdir -p "$CLAUDE_DIR/bin"
install_one() {  # src dst
  rm -f "$2"
  if [ "$MODE" = copy ]; then cp "$1" "$2"; else ln -s "$1" "$2"; fi
}
chmod 755 "$ROOT/bin/claude-acct"
install_one "$ROOT/bin/claude-acct" "$BIN"
install_one "$ROOT/shell/claude-acct.sh" "$GLUE"

if [ "$NO_RC" = 0 ]; then
  # Exactly one source line in the rc file, whatever state it was in: a stale
  # account-switcher.sh line from an older install gets replaced, not stacked.
  if [ -f "$RC" ] && grep -q -e 'claude-acct.sh' -e 'account-switcher.sh' "$RC"; then
    rc_edit "$RC" replace "$SOURCE_LINE" >/dev/null
    echo "updated the source line in $RC (backup at $RC.pre-claude-acct.bak)"
    [ -L "$LEGACY_GLUE" ] && rm -f "$LEGACY_GLUE"
  else
    {
      echo
      echo '# claude-acct — Claude Code account switcher'
      echo "$SOURCE_LINE"
    } >> "$RC"
    echo "added the source line to $RC"
  fi
  case "$RC" in
    *zshrc) command -v zsh >/dev/null && { zsh -n "$RC" || echo "warning: $RC has a syntax error" >&2; } ;;
    *) bash -n "$RC" || echo "warning: $RC has a syntax error — check it before opening a new shell" >&2 ;;
  esac
fi

echo
echo "installed:"
echo "  $BIN$([ "$MODE" = link ] && echo "  ->  $ROOT/bin/claude-acct")"
echo "  $GLUE$([ "$MODE" = link ] && echo "  ->  $ROOT/shell/claude-acct.sh")"
echo
if [ "$NO_RC" = 0 ]; then
  echo "Open a new terminal, then:  claude-acct"
else
  echo "Run it with:  $BIN"
fi
