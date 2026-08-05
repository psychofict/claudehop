# shellcheck shell=bash
# Show the active Claude account in the Claude Code statusline.
# Paste this into your ~/.claude/statusline.sh, where $out is the line being built.
# It reads one small file rather than calling the API — the statusline runs
# constantly — and stays quiet until you have more than one account saved.
#
# Note it reflects what the credential store points at, which is what a NEW
# session would start as. A long-running session that you switched away from
# still shows the name of the account now on disk, not its own.

acct_dir="${CLAUDE_ACCOUNTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/accounts}"
if [ -r "$acct_dir/active" ]; then
  set -- "$acct_dir"/*.json
  if [ "$#" -gt 1 ]; then
    out+=" ${DIM}·${OFF} ${DIM}@$(cat "$acct_dir/active")${OFF}"
  fi
fi
