#!/usr/bin/env bash
# Exercises claude-acct against a throwaway config dir with fake credentials.
# No network, no real Claude account, nothing outside $TMP is touched.
#
#   ./test/test-switch.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCT="$ROOT/bin/claude-acct"
TMP="$(mktemp -d -t claude-acct-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_CONFIG_DIR="$TMP"
export CLAUDE_ACCOUNTS_DIR="$TMP/accounts"
export CLAUDE_ACCT_OFFLINE=1          # never call the API from tests
mkdir -p "$CLAUDE_ACCOUNTS_DIR"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }

jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d = d[k] if isinstance(d,dict) else d
print(d)" "$1" "$2" 2>/dev/null; }

live_token() { jget "$TMP/.credentials.json" "claudeAiOauth.accessToken"; }
saved_token() { jget "$CLAUDE_ACCOUNTS_DIR/$1.json" "claudeAiOauth.accessToken"; }

seed() {
  rm -rf "$TMP"/.credentials.json "$CLAUDE_ACCOUNTS_DIR"; mkdir -p "$CLAUDE_ACCOUNTS_DIR"
  cat > "$TMP/.credentials.json" <<'J'
{"mcpOAuth":{"vercel|x":{"accessToken":"vca_KEEPME"}},
 "claudeAiOauth":{"accessToken":"tok-A","refreshToken":"r-A","expiresAt":99999999999999,"subscriptionType":"max"}}
J
  python3 - <<'PY'
import json, os
d = os.environ['CLAUDE_ACCOUNTS_DIR']
for n, t, u in (('alpha', 'tok-A', 'uuid-A'), ('beta', 'tok-B', 'uuid-B')):
    json.dump({"name": n, "email": f"{n}@x.com", "plan": "max", "accountUuid": u,
               "claudeAiOauth": {"accessToken": t, "refreshToken": "r-" + n,
                                 "expiresAt": 99999999999999}},
              open(f"{d}/{n}.json", "w"))
PY
  chmod 600 "$CLAUDE_ACCOUNTS_DIR"/*.json
  echo alpha > "$CLAUDE_ACCOUNTS_DIR/active"
}

echo "claude-acct test suite"

# --- 1. a plain switch --------------------------------------------------------
seed
"$ACCT" use beta >/dev/null 2>&1
is "switch loads the target credentials"   "$(live_token)" "tok-B"
is "mcpOAuth block survives the swap"      "$(jget "$TMP/.credentials.json" 'mcpOAuth.vercel|x.accessToken')" "vca_KEEPME"
is "active pointer follows the switch"     "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "beta"

# --- 2. Claude Code rotates the token, then we switch away --------------------
# The regression that mattered: the live token no longer equals anything on
# disk, so the profile must be identified by the pointer, not by token value.
python3 -c "
import json,os
p=os.environ['CLAUDE_CONFIG_DIR']+'/.credentials.json'; d=json.load(open(p))
d['claudeAiOauth']['accessToken']='tok-B-refreshed'; json.dump(d,open(p,'w'))"
"$ACCT" use alpha >/dev/null 2>&1
is "rotated token is synced back to its profile" "$(saved_token beta)" "tok-B-refreshed"
is "switching back restores the rotated token"   "$( "$ACCT" use beta >/dev/null 2>&1; live_token)" "tok-B-refreshed"
[ -z "$(ls "$CLAUDE_ACCOUNTS_DIR"/unsaved-*.json 2>/dev/null)" ] \
  && ok "no junk unsaved-* profile created" \
  || bad "no junk unsaved-* profile created" "found $(ls "$CLAUDE_ACCOUNTS_DIR"/unsaved-*.json)"

# --- 3. a login we do not recognise is stashed, never overwritten -------------
seed
python3 -c "
import json,os
p=os.environ['CLAUDE_CONFIG_DIR']+'/.credentials.json'; d=json.load(open(p))
d['claudeAiOauth']['accessToken']='tok-STRANGER'; json.dump(d,open(p,'w'))"
rm "$CLAUDE_ACCOUNTS_DIR/active"
"$ACCT" use beta >/dev/null 2>&1
[ -n "$(grep -l tok-STRANGER "$CLAUDE_ACCOUNTS_DIR"/*.json 2>/dev/null)" ] \
  && ok "unknown login is stashed before being replaced" \
  || bad "unknown login is stashed before being replaced" "tok-STRANGER is gone"
is "alpha was not clobbered by the stash" "$(saved_token alpha)" "tok-A"

# --- 4. ergonomics ------------------------------------------------------------
seed
is "bare name is shorthand for use"  "$( "$ACCT" beta >/dev/null 2>&1; live_token)" "tok-B"
"$ACCT" use beta 2>/dev/null | grep -q "already on" && ok "re-switching is a no-op" || bad "re-switching is a no-op" "expected 'already on'"
"$ACCT" use nope >/dev/null 2>&1; is "unknown account exits non-zero" "$?" "1"
"$ACCT" list 2>/dev/null | grep -q '^\*  beta' && ok "list marks the active account" || bad "list marks the active account" "no * on beta"

# --- 5. housekeeping ----------------------------------------------------------
"$ACCT" rename alpha one >/dev/null 2>&1
[ -f "$CLAUDE_ACCOUNTS_DIR/one.json" ] && [ ! -e "$CLAUDE_ACCOUNTS_DIR/alpha.json" ] && [ ! -e "$CLAUDE_ACCOUNTS_DIR/alpha.json.bak" ] \
  && ok "rename leaves no stale files" || bad "rename leaves no stale files" "$(ls "$CLAUDE_ACCOUNTS_DIR")"
"$ACCT" rm one -y >/dev/null 2>&1
[ ! -e "$CLAUDE_ACCOUNTS_DIR/one.json" ] && [ ! -e "$CLAUDE_ACCOUNTS_DIR/one.json.bak" ] \
  && ok "rm removes the profile and its backup" || bad "rm removes the profile and its backup" "$(ls "$CLAUDE_ACCOUNTS_DIR")"

# --- 6. permissions -----------------------------------------------------------
is "accounts dir is 700"      "$(stat -c '%a' "$CLAUDE_ACCOUNTS_DIR")" "700"
is "profiles are 600"         "$(stat -c '%a' "$CLAUDE_ACCOUNTS_DIR/beta.json")" "600"
is "credentials stay 600"     "$(stat -c '%a' "$TMP/.credentials.json")" "600"
[ -z "$(find "$CLAUDE_ACCOUNTS_DIR" -name '*.bak' -perm /077 2>/dev/null)" ] \
  && ok "backups are not world/group readable" || bad "backups are not world/group readable" "$(find "$CLAUDE_ACCOUNTS_DIR" -name '*.bak' -perm /077)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
