#!/usr/bin/env bash
# Install claudehop into ~/.claude and wire it into your shell.
#
#   ./install.sh              symlink from this repo (edits here take effect at once)
#   ./install.sh --copy       copy the files instead
#   ./install.sh --rc FILE    use a specific shell rc instead of guessing
#   ./install.sh --no-rc      install the files only, don't touch any rc file
#   ./install.sh --uninstall  remove what this installed (never touches accounts/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BIN="$CLAUDE_DIR/bin/claudehop"
GLUE="$CLAUDE_DIR/claudehop.sh"

# Names this tool has been installed under before. Removed on install and on
# uninstall so an upgrade never leaves two copies on your PATH.
LEGACY=(
  "$CLAUDE_DIR/bin/claude-acct"
  "$CLAUDE_DIR/claude-acct.sh"
  "$CLAUDE_DIR/account-switcher.sh"
)
# Any of these in an rc file is our line, whatever version wrote it.
RC_MARKERS=(claudehop.sh claude-acct.sh account-switcher.sh)

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
  echo "claudehop needs python3 on your PATH." >&2; exit 1; }

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

COMMENT_LINE='# claudehop — Claude Code account switcher'
SOURCE_LINE='[ -f "$HOME/.claude/claudehop.sh" ] && source "$HOME/.claude/claudehop.sh"'
# Comment lines we have written into rc files over the versions. Recognised so
# an upgrade refreshes ours instead of leaving one that names the old tool.
OUR_COMMENTS='# claudehop|# claude-acct|# Claude Code account switcher'

rc_has_our_line() {  # rc_has_our_line <file>
  [ -f "$1" ] || return 1
  local m
  for m in "${RC_MARKERS[@]}"; do
    grep -q -- "$m" "$1" && return 0
  done
  return 1
}

# Line edits go through python, not sed: the source line contains `&&`, and `&`
# in a sed replacement means "the whole match" — which silently duplicates the
# line it was meant to replace. (BSD and GNU sed also disagree on -i.)
rc_edit() {  # rc_edit <rc file> <drop|replace> <block> <comment prefixes> <marker>...
  python3 - "$@" <<'PY'
import shutil, sys
rc, mode, block = sys.argv[1], sys.argv[2], sys.argv[3]
comments, markers = sys.argv[4].split("|"), sys.argv[5:]
try:
    src = open(rc).read().splitlines()
except FileNotFoundError:
    src = []

def ours(s):
    """One of our lines: the source line, or a comment we wrote above it."""
    return any(m in s for m in markers) or s.strip().startswith(tuple(comments))

out, replaced = [], False
for s in src:
    if not ours(s):
        out.append(s)
    elif mode == "replace" and not replaced:
        out.extend(block.splitlines())
        replaced = True
if mode == "drop":
    # Removing our block leaves the blank line that separated it; don't grow a
    # gap in someone's rc file every time they reinstall.
    collapsed = []
    for s in out:
        if not s.strip() and collapsed and not collapsed[-1].strip():
            continue
        collapsed.append(s)
    out = collapsed
while out and not out[-1].strip():
    out.pop()
if src:
    shutil.copy2(rc, rc + ".pre-claudehop.bak")
open(rc, "w").write("\n".join(out) + "\n")
print("replaced" if replaced else "dropped")
PY
}

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$BIN" "$GLUE" "${LEGACY[@]}"
  if [ "$NO_RC" = 0 ] && rc_has_our_line "$RC"; then
    rc_edit "$RC" drop "" "$OUR_COMMENTS" "${RC_MARKERS[@]}" >/dev/null
    echo "cleaned $RC (backup at $RC.pre-claudehop.bak)"
  fi
  echo "uninstalled. Your saved accounts in $CLAUDE_DIR/accounts are untouched."
  exit 0
fi

mkdir -p "$CLAUDE_DIR/bin"
install_one() {  # src dst
  rm -f "$2"
  if [ "$MODE" = copy ]; then cp "$1" "$2"; else ln -s "$1" "$2"; fi
}
chmod 755 "$ROOT/bin/claudehop"
install_one "$ROOT/bin/claudehop" "$BIN"
install_one "$ROOT/shell/claudehop.sh" "$GLUE"
# The old command name keeps working as a shell function from the glue, so the
# stale binary and glue from a claude-acct install just go.
rm -f "${LEGACY[@]}"

if [ "$NO_RC" = 0 ]; then
  # Exactly one source line in the rc file, whatever state it was in: a stale
  # claude-acct.sh line from an older install gets replaced, not stacked.
  if rc_has_our_line "$RC"; then
    rc_edit "$RC" replace "$COMMENT_LINE
$SOURCE_LINE" "$OUR_COMMENTS" "${RC_MARKERS[@]}" >/dev/null
    echo "updated the source line in $RC (backup at $RC.pre-claudehop.bak)"
  else
    {
      echo
      echo "$COMMENT_LINE"
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
echo "  $BIN$([ "$MODE" = link ] && echo "  ->  $ROOT/bin/claudehop")"
echo "  $GLUE$([ "$MODE" = link ] && echo "  ->  $ROOT/shell/claudehop.sh")"
echo
if [ "$NO_RC" = 0 ]; then
  echo "Open a new terminal, then:  claudehop     (or just: hop)"
else
  echo "Run it with:  $BIN"
fi
