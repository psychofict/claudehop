# shellcheck shell=bash
# claude-acct — shell glue. Sourced from your shell rc by install.sh.
# The tool itself is ~/.claude/bin/claude-acct.
#
#   claude-acct                 list saved accounts (* = active)
#   claude-acct use <name>      switch  (also: claude-acct <name>)
#   claude-acct add <name>      log in as a new account and save it
#   claude-acct whoami          who am I right now
#
# Switching rewrites the claudeAiOauth block in Claude Code's credential store,
# so it takes effect for every NEW `claude` you start. Sessions already running
# keep the account they started with.
#
# https://github.com/psychofict/claude-acct

_claude_acct_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
export CLAUDE_ACCOUNTS_DIR="${CLAUDE_ACCOUNTS_DIR:-$_claude_acct_home/accounts}"

case ":$PATH:" in
  *":$_claude_acct_home/bin:"*) ;;
  *) export PATH="$_claude_acct_home/bin:$PATH" ;;
esac
unset _claude_acct_home

alias cacct='claude-acct'

_claude_acct_names() {
  local d="${CLAUDE_ACCOUNTS_DIR:-$HOME/.claude/accounts}" f n
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    n="${f##*/}"
    printf '%s ' "${n%.json}"
  done
}

_claude_acct_verbs='list use add save whoami active sync rm rename doctor help'

# --- completion ---------------------------------------------------------------
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: reuse the bash completion function through bashcompinit.
  autoload -Uz +X bashcompinit 2>/dev/null && bashcompinit 2>/dev/null
fi

# shellcheck disable=SC2207  # the compgen split is the point of a completion
_claude_acct_complete() {
  local cur prev names
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  names="$(_claude_acct_names)"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$_claude_acct_verbs $names" -- "$cur"))
  else
    case "$prev" in
      use|switch|rm|remove|delete|rename|mv|save|add|new|login)
        COMPREPLY=($(compgen -W "$names" -- "$cur")) ;;
      *)
        COMPREPLY=($(compgen -W "--verify --yes --no-sync --json --fix --no-color" -- "$cur")) ;;
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
