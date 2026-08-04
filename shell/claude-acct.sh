# Claude Code account switcher — shell glue for `claude-acct`.
# Sourced from your shell rc. The tool itself is ~/.claude/bin/claude-acct.
# Repo: https://github.com/  (local: ~/Downloads/claude-acct)
#
#   claude-acct                 list saved accounts (* = active)
#   claude-acct use <name>      switch  (also: claude-acct <name>)
#   claude-acct add <name>      log in as a new account and save it
#   claude-acct whoami          who am I right now
#
# Switching rewrites the claudeAiOauth block in ~/.claude/.credentials.json,
# so it takes effect for every NEW `claude` you start. Sessions already running
# keep the account they started with.

export CLAUDE_ACCOUNTS_DIR="${CLAUDE_ACCOUNTS_DIR:-$HOME/.claude/accounts}"
case ":$PATH:" in
  *":$HOME/.claude/bin:"*) ;;
  *) export PATH="$HOME/.claude/bin:$PATH" ;;
esac

alias cacct='claude-acct'

# Tab-completion for account names.
_claude_acct_complete() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  local names
  names="$(ls "$CLAUDE_ACCOUNTS_DIR" 2>/dev/null | sed -n 's/\.json$//p' | tr '\n' ' ')"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "list use add save whoami sync rm rename help $names" -- "$cur"))
  else
    case "$prev" in
      use|switch|rm|remove|delete|rename|mv|save|add|new|login)
        COMPREPLY=($(compgen -W "$names" -- "$cur")) ;;
      *) COMPREPLY=($(compgen -W "--verify --yes --no-sync" -- "$cur")) ;;
    esac
  fi
}
complete -F _claude_acct_complete claude-acct cacct 2>/dev/null

# --- back-compat with the old token-env switcher -----------------------------
# The old scheme exported CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token`.
# Those tokens die and only carry inference scope, so these now call claude-acct.
use-account()     { claude-acct use "$@"; }
claude-whoami()   { claude-acct whoami "$@"; }
claude-token-set() {
  echo "claude-token-set is gone — setup-token tokens expire and can't be listed." >&2
  echo "Use:  claude-acct add ${1:-<name>}   (real /login, saved and switchable)" >&2
  return 1
}
