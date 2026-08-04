# Show the active Claude account in the Claude Code statusline.
# Paste this into your ~/.claude/statusline.sh, where $out is the line being built.
# It only shows anything once you have more than one account saved, and it reads
# a file rather than calling the API — the statusline runs constantly.
#
# Note it reflects what the credentials file points at, which is what a NEW
# session would start as. A long-running session that you switched away from
# still shows the name of the account now on disk, not its own.

acct_dir="${CLAUDE_ACCOUNTS_DIR:-$HOME/.claude/accounts}"
if [ -r "$acct_dir/active" ] && [ "$(ls "$acct_dir"/*.json 2>/dev/null | wc -l)" -gt 1 ]; then
  out+=" ${DIM}·${OFF} ${DIM}@$(cat "$acct_dir/active")${OFF}"
fi
