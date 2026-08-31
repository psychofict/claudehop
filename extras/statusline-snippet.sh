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

# --- and a countdown to the next real login ----------------------------------
# A login lasts up to ~30 days and that date is fixed when you log in: renewing
# rotates the token but never moves it. So the only useful thing to show is how
# long is left before `hop add <name>` has to be done by hand. Parsed with grep
# rather than a JSON parser, because the statusline runs on every render.
#
# The active account is read from the credential store, not from its saved copy.
# Claude Code rotates the live token behind that snapshot, so the snapshot can
# be days stale while the login itself is perfectly good.

# claudehop writes the saved profiles with indent=2 and Claude Code writes the
# credential store compact, so the separator is ": " in one and ":" in the other.
hop_exp_ms() { grep -o '"refreshTokenExpiresAt"[[:space:]]*:[[:space:]]*[0-9]*' "$1" \
                 | head -1 | tr -cd '0-9'; }

hop_relogin_days() {
  local dir creds active now earliest f name ms
  dir="${CLAUDE_ACCOUNTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/accounts}"
  creds="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  [ -d "$dir" ] || return 1
  active="$(cat "$dir/active" 2>/dev/null)"
  now="$(date +%s)"
  earliest=""
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    name="${f##*/}"; name="${name%.json}"
    if [ "$name" = "$active" ] && [ -r "$creds" ]; then
      ms="$(hop_exp_ms "$creds")"
    else
      ms="$(hop_exp_ms "$f")"
    fi
    [ -n "$ms" ] || continue
    if [ -z "$earliest" ] || [ "$ms" -lt "$earliest" ]; then earliest="$ms"; fi
  done
  [ -n "$earliest" ] || return 1
  echo "$(( (earliest / 1000 - now) / 86400 ))"
}

hop_days="$(hop_relogin_days)"
if [ -n "$hop_days" ] && [ "$hop_days" -le 7 ]; then
  if [ "$hop_days" -le 0 ]; then
    out+=" ${DIM}·${OFF} ${RED}login due${OFF}"
  else
    out+=" ${DIM}·${OFF} ${YELLOW}login ${hop_days}d${OFF}"
  fi
fi
