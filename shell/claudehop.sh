# shellcheck shell=bash
# claudehop — shell glue. Sourced from your shell rc by install.sh.
# The tool itself is ~/.claude/bin/claudehop.
#
#   claudehop                 show your accounts, pick one to hop to
#   claudehop <name>          hop straight to that account
#   claudehop add <name>      log in as a new account and save it
#   claudehop whoami          who am I right now
#
# Hopping rewrites the claudeAiOauth block in Claude Code's credential store,
# so it takes effect for every NEW `claude` you start. Sessions already running
# keep the account they started with.
#
# https://github.com/psychofict/claudehop

_claudehop_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
export CLAUDE_ACCOUNTS_DIR="${CLAUDE_ACCOUNTS_DIR:-$_claudehop_home/accounts}"

case ":$PATH:" in
  *":$_claudehop_home/bin:"*) ;;
  *) export PATH="$_claudehop_home/bin:$PATH" ;;
esac
unset _claudehop_home

alias hop='claudehop'

_claudehop_names() {
  local d="${CLAUDE_ACCOUNTS_DIR:-$HOME/.claude/accounts}" f n
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    n="${f##*/}"
    printf '%s ' "${n%.json}"
  done
}

_claudehop_verbs='list use add save whoami active sync rm rename doctor help'

# --- completion ---------------------------------------------------------------
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: reuse the bash completion function through bashcompinit.
  autoload -Uz +X bashcompinit 2>/dev/null && bashcompinit 2>/dev/null
fi

# shellcheck disable=SC2207  # the compgen split is the point of a completion
_claudehop_complete() {
  local cur prev names
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  names="$(_claudehop_names)"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$_claudehop_verbs $names" -- "$cur"))
  else
    case "$prev" in
      use|switch|rm|remove|delete|rename|mv|save|add|new|login)
        COMPREPLY=($(compgen -W "$names" -- "$cur")) ;;
      *)
        COMPREPLY=($(compgen -W "--verify --long --yes --no-sync --json --fix --no-color" -- "$cur")) ;;
    esac
  fi
}
complete -F _claudehop_complete claudehop hop claude-acct cacct 2>/dev/null

# --- back-compat -------------------------------------------------------------
# The tool was called claude-acct until 1.2.0, and the scheme before that
# exported CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token`. Those tokens die
# and only carry inference scope, so all of these now call claudehop.
claude-acct()     { claudehop "$@"; }
cacct()           { claudehop "$@"; }
use-account()     { claudehop use "$@"; }
claude-whoami()   { claudehop whoami "$@"; }
claude-token-set() {
  echo "claude-token-set is gone — setup-token tokens expire and can't be listed." >&2
  echo "Use:  claudehop add ${1:-<name>}   (real /login, saved and switchable)" >&2
  return 1
}
