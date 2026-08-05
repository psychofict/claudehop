#!/usr/bin/env bash
# Exercises claudehop against a throwaway config dir with fake credentials.
# No network, no real Claude account, nothing outside $TMP is touched.
#
#   ./test/test-switch.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOP="$ROOT/bin/claudehop"
TMP="$(mktemp -d -t claudehop-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_CONFIG_DIR="$TMP"
export CLAUDE_ACCOUNTS_DIR="$TMP/accounts"
export CLAUDE_HOP_OFFLINE=1           # never call the API from tests
export CLAUDE_HOP_BACKEND=file        # the keychain section overrides this
export NO_COLOR=1
mkdir -p "$CLAUDE_ACCOUNTS_DIR" "$TMP/bin"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }
yes_() { [ -n "$2" ] && ok "$1" || bad "$1" "${3:-empty}"; }

jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d = d[k] if isinstance(d,dict) else d
print(d)" "$1" "$2" 2>/dev/null; }

live_token() { jget "$TMP/.credentials.json" "claudeAiOauth.accessToken"; }
saved_token() { jget "$CLAUDE_ACCOUNTS_DIR/$1.json" "claudeAiOauth.accessToken"; }

seed() {
  rm -rf "$TMP"/.credentials.json "$TMP"/.credentials.json.bak "$CLAUDE_ACCOUNTS_DIR"
  mkdir -p "$CLAUDE_ACCOUNTS_DIR"
  cat > "$TMP/.credentials.json" <<'J'
{"mcpOAuth":{"vercel|x":{"accessToken":"vca_KEEPME"}},
 "claudeAiOauth":{"accessToken":"tok-A","refreshToken":"r-A","expiresAt":99999999999999,"subscriptionType":"max"}}
J
  chmod 600 "$TMP/.credentials.json"
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

echo "claudehop test suite"

# --- 1. a plain switch --------------------------------------------------------
seed
"$HOP" use beta >/dev/null 2>&1
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
"$HOP" use alpha >/dev/null 2>&1
is "rotated token is synced back to its profile" "$(saved_token beta)" "tok-B-refreshed"
is "switching back restores the rotated token"   "$( "$HOP" use beta >/dev/null 2>&1; live_token)" "tok-B-refreshed"
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
"$HOP" use beta >/dev/null 2>&1
[ -n "$(grep -l tok-STRANGER "$CLAUDE_ACCOUNTS_DIR"/*.json 2>/dev/null)" ] \
  && ok "unknown login is stashed before being replaced" \
  || bad "unknown login is stashed before being replaced" "tok-STRANGER is gone"
is "alpha was not clobbered by the stash" "$(saved_token alpha)" "tok-A"

# --- 4. ergonomics ------------------------------------------------------------
seed
is "bare name is shorthand for use"  "$( "$HOP" beta >/dev/null 2>&1; live_token)" "tok-B"
"$HOP" use beta 2>/dev/null | grep -q "already on" && ok "re-switching is a no-op" || bad "re-switching is a no-op" "expected 'already on'"
"$HOP" use nope >/dev/null 2>&1; is "unknown account exits non-zero" "$?" "1"
"$HOP" list 2>/dev/null | grep -q '^\*  beta' && ok "list marks the active account" || bad "list marks the active account" "no * on beta"
is "active prints just the name"     "$("$HOP" active 2>/dev/null)" "beta"
"$HOP" --version | grep -q '^claudehop [0-9]' && ok "--version prints a version" || bad "--version prints a version" "$("$HOP" --version)"
"$HOP" list --bogus >/dev/null 2>&1; is "unknown option exits 2" "$?" "2"
"$HOP" save 'bad/name' -y >/dev/null 2>&1; is "a name with a slash is rejected" "$?" "1"
[ ! -e "$CLAUDE_ACCOUNTS_DIR/bad" ] && ok "a rejected name writes nothing" || bad "a rejected name writes nothing" "$(ls "$CLAUDE_ACCOUNTS_DIR")"
"$HOP" list 2>/dev/null | head -1 >/dev/null 2>&1; is "list survives a closed pipe" "$?" "0"

# --- 5. table layout ----------------------------------------------------------
# Colour codes inside a cell used to be counted as width, so an expired token
# knocked every later column out of line.
python3 -c "
import json,os
d=os.environ['CLAUDE_ACCOUNTS_DIR']+'/alpha.json'; p=json.load(open(d))
p['claudeAiOauth']['expiresAt']=1000; json.dump(p,open(d,'w'))"
strip_ansi() { python3 -c 'import re,sys;sys.stdout.write(re.sub("\033\\[[0-9;]*m","",sys.stdin.read()))'; }
plan_cols() {  # column where the PLAN cell starts, one number per data row
  CLICOLOR_FORCE=1 "$HOP" list 2>/dev/null \
    | strip_ansi | tail -n +2 \
    | awk '{print index($0,"max")}' | sort -u | tr '\n' ' '
}
[ "$(plan_cols | wc -w)" -eq 1 ] \
  && ok "columns line up even with colour in a cell" \
  || bad "columns line up even with colour in a cell" "PLAN starts at columns: $(plan_cols)"
CLICOLOR_FORCE=1 "$HOP" list 2>/dev/null | grep -q 'expired' \
  && ok "an expired token is called out" || bad "an expired token is called out" "no 'expired' in the table"

# --- 6. json output -----------------------------------------------------------
seed
"$HOP" use beta >/dev/null 2>&1
out="$("$HOP" list --json 2>/dev/null)"
is "list --json reports the active account" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["active"])')" "beta"
printf '%s' "$out" | grep -q 'tok-' && bad "json output leaks no tokens" "found a token in the JSON" || ok "json output leaks no tokens"
is "list --json is valid json" "$(printf '%s' "$out" | python3 -c 'import json,sys;json.load(sys.stdin);print("ok")')" "ok"

# --- 7. housekeeping ----------------------------------------------------------
seed
"$HOP" rename alpha one >/dev/null 2>&1
[ -f "$CLAUDE_ACCOUNTS_DIR/one.json" ] && [ ! -e "$CLAUDE_ACCOUNTS_DIR/alpha.json" ] && [ ! -e "$CLAUDE_ACCOUNTS_DIR/alpha.json.bak" ] \
  && ok "rename leaves no stale files" || bad "rename leaves no stale files" "$(ls "$CLAUDE_ACCOUNTS_DIR")"
is "rename moves the active pointer" "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "one"
"$HOP" rm one -y >/dev/null 2>&1
[ ! -e "$CLAUDE_ACCOUNTS_DIR/one.json" ] && [ ! -e "$CLAUDE_ACCOUNTS_DIR/one.json.bak" ] \
  && ok "rm removes the profile and its backup" || bad "rm removes the profile and its backup" "$(ls "$CLAUDE_ACCOUNTS_DIR")"
[ ! -e "$CLAUDE_ACCOUNTS_DIR/active" ] \
  && ok "rm clears a pointer that named it" || bad "rm clears a pointer that named it" "$(cat "$CLAUDE_ACCOUNTS_DIR/active")"

# --- 8. permissions -----------------------------------------------------------
seed
"$HOP" use beta >/dev/null 2>&1
mode() { python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])" "$1"; }
is "accounts dir is 700"      "$(mode "$CLAUDE_ACCOUNTS_DIR")" "700"
is "profiles are 600"         "$(mode "$CLAUDE_ACCOUNTS_DIR/beta.json")" "600"
is "credentials stay 600"     "$(mode "$TMP/.credentials.json")" "600"
# `find -perm /077` is GNU-only, so ask python instead.
loose="$(python3 -c "
import os, sys
bad = []
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        if f.endswith('.bak'):
            p = os.path.join(root, f)
            if os.stat(p).st_mode & 0o077:
                bad.append(p)
print(' '.join(bad))" "$TMP")"
[ -z "$loose" ] \
  && ok "backups are not world/group readable" || bad "backups are not world/group readable" "$loose"
[ -z "$(ls "$CLAUDE_ACCOUNTS_DIR"/*.json.bak 2>/dev/null)" ] \
  && ok "no stale credential copies pile up in accounts/" || bad "no stale credential copies pile up in accounts/" "$(ls "$CLAUDE_ACCOUNTS_DIR")"

# --- 9. doctor ----------------------------------------------------------------
seed
"$HOP" doctor >/dev/null 2>&1; is "doctor is quiet on a healthy setup" "$?" "0"
echo '{"name":"broken"}' > "$CLAUDE_ACCOUNTS_DIR/broken.json"
"$HOP" doctor >/dev/null 2>&1; is "doctor exits non-zero on a real problem" "$?" "1"
out="$("$HOP" doctor 2>/dev/null)"
case "$out" in *"'broken' has no saved credentials"*) ok "doctor names the broken account" ;;
              *) bad "doctor names the broken account" "$out" ;; esac
rm -f "$CLAUDE_ACCOUNTS_DIR/broken.json"
cp "$CLAUDE_ACCOUNTS_DIR/beta.json" "$CLAUDE_ACCOUNTS_DIR/beta.json.bak"
"$HOP" doctor --fix >/dev/null 2>&1
[ ! -e "$CLAUDE_ACCOUNTS_DIR/beta.json.bak" ] \
  && ok "doctor --fix clears stale credential copies" || bad "doctor --fix clears stale credential copies" "beta.json.bak still there"
"$HOP" doctor --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["backend"])' | grep -q file \
  && ok "doctor --json names the backend" || bad "doctor --json names the backend" "no backend field"

# --- 10. concurrent switches do not corrupt anything --------------------------
seed
for _ in 1 2 3 4 5 6; do
  ( "$HOP" use alpha >/dev/null 2>&1 ) &
  ( "$HOP" use beta  >/dev/null 2>&1 ) &
done
wait
python3 - <<'PY' && ok "concurrent switches leave valid files" || bad "concurrent switches leave valid files" "corrupt json"
import json, os, sys
tmp = os.environ['CLAUDE_CONFIG_DIR']; acc = os.environ['CLAUDE_ACCOUNTS_DIR']
json.load(open(f"{tmp}/.credentials.json"))
for f in os.listdir(acc):
    if f.endswith('.json'):
        json.load(open(os.path.join(acc, f)))
PY
[ -z "$(ls "$CLAUDE_ACCOUNTS_DIR"/*.tmp-claudehop* 2>/dev/null)" ] \
  && ok "no temp files left behind" || bad "no temp files left behind" "$(ls "$CLAUDE_ACCOUNTS_DIR")"

# --- 11. macOS keychain backend (driven through a fake `security`) ------------
cat > "$TMP/bin/security" <<'SH'
#!/usr/bin/env bash
# Minimal stand-in for macOS `security` — enough of find/add-generic-password
# to exercise the keychain backend on any platform.
store="$KEYCHAIN_FAKE"
cmd="$1"; shift
svc=""; want_pw=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift ;;
    -a) shift ;;
    -w) want_pw=1 ;;
    -X) printf '%s' "$2" > "$store"; shift ;;
    -U) ;;
  esac
  shift
done
case "$cmd" in
  find-generic-password)
    [ -s "$store" ] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; }
    [ "$want_pw" = 1 ] && cat "$store"
    exit 0 ;;
  add-generic-password) exit 0 ;;
esac
exit 1
SH
chmod +x "$TMP/bin/security"
export KEYCHAIN_FAKE="$TMP/keychain.hex"
: > "$KEYCHAIN_FAKE"

seed
rm -f "$TMP/.credentials.json"
python3 - <<'PY'
import binascii, json, os
doc = {"mcpOAuth": {"vercel|x": {"accessToken": "vca_KEEPME"}},
       "claudeAiOauth": {"accessToken": "tok-A", "refreshToken": "r-A",
                         "expiresAt": 99999999999999}}
open(os.environ['KEYCHAIN_FAKE'], 'w').write(binascii.hexlify(json.dumps(doc).encode()).decode())
PY
kc() { PATH="$TMP/bin:$PATH" CLAUDE_HOP_BACKEND=keychain "$HOP" "$@"; }
kc_token() { python3 -c "
import binascii, json, os
raw = open(os.environ['KEYCHAIN_FAKE']).read().strip()
try: d = json.loads(raw)
except ValueError: d = json.loads(binascii.unhexlify(raw).decode())
print(d['claudeAiOauth']['accessToken'])"; }

kc use beta >/dev/null 2>&1
is "keychain backend switches the account" "$(kc_token)" "tok-B"
is "keychain backend keeps mcpOAuth" "$(python3 -c "
import binascii,json,os
d=json.loads(binascii.unhexlify(open(os.environ['KEYCHAIN_FAKE']).read().strip()).decode())
print(d['mcpOAuth']['vercel|x']['accessToken'])")" "vca_KEEPME"
[ ! -e "$TMP/.credentials.json" ] \
  && ok "keychain backend never writes the credentials file" || bad "keychain backend never writes the credentials file" "file exists"
is "keychain backend reports itself" "$(kc doctor --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["backend"])')" "keychain"

# --- 12. `add` never leaves you logged out ------------------------------------
# `add` clears the live credentials before handing you to `claude` for /login.
# If that produces nothing — no `claude`, an immediate exit, Ctrl-C — the old
# credentials must come back. Driven in-process: it needs a tty and a `claude`,
# and faking both with a pty hangs on some platforms.
add_with() {  # add_with <python body for the fake `claude` run>
  HOP="$HOP" FAKE_CLAUDE="$1" python3 - <<'PY' >/dev/null 2>&1
import importlib.machinery, importlib.util, json, os, sys

loader = importlib.machinery.SourceFileLoader("ca", os.environ["HOP"])
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", loader))
loader.exec_module(ca)

class Tty:                      # cmd_add insists on a real terminal
    def isatty(self):
        return True
sys.stdin = Tty()
ca.shutil.which = lambda cmd: "/bin/true"
ca.subprocess.call = lambda *a, **k: exec(os.environ["FAKE_CLAUDE"], {"ca": ca, "json": json})
try:
    ca.cmd_add(name="gamma", yes=True)
except SystemExit:
    pass
PY
}

seed
add_with 'pass'                                  # `claude` exits, nobody logs in
is "a failed add restores the previous login" "$(live_token)" "tok-A"
[ ! -e "$CLAUDE_ACCOUNTS_DIR/gamma.json" ] \
  && ok "a failed add saves no profile" || bad "a failed add saves no profile" "gamma.json exists"

seed
add_with 'raise KeyboardInterrupt'               # Ctrl-C at the login prompt
is "Ctrl-C during add restores the previous login" "$(live_token)" "tok-A"

seed
add_with 'ca.set_live_oauth({"accessToken": "tok-NEW", "expiresAt": 99999999999999})'
is "a real login is saved under the new name" "$(saved_token gamma)" "tok-NEW"
is "the new account becomes active"           "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "gamma"
is "the account we were on was saved first"   "$(saved_token alpha)" "tok-A"

# --- 13. unit checks on the tricky helpers ------------------------------------
unit() {  # unit <name> <python expression> <expected>
  local got
  got="$(HOP="$HOP" python3 - "$2" <<'PY'
import importlib.machinery, importlib.util, os, sys, time
loader = importlib.machinery.SourceFileLoader("ca", os.environ["HOP"])
spec = importlib.util.spec_from_loader("ca", loader)
ca = importlib.util.module_from_spec(spec)
loader.exec_module(ca)
print(eval(sys.argv[1], {"ca": ca, "time": time}))
PY
)"
  is "$1" "$got" "$3"
}
now=$(python3 -c 'import time;print(int(time.time()*1000))')
unit "an aged-out access token reads as stale, not invalid" \
     "ca.token_state({'expiresAt': $now - 60000, 'refreshTokenExpiresAt': $now + 9999999}, {'tokenState':'invalid'})" \
     "stale (renews)"
unit "a genuinely rejected live token still reads as invalid" \
     "ca.token_state({'expiresAt': $now + 9999999}, {'tokenState':'invalid'})" \
     "invalid"
unit "a dead refresh token is not called renewable" \
     "ca.token_state({'expiresAt': $now - 60000, 'refreshTokenExpiresAt': $now - 10}, {'tokenState':'invalid'})" \
     "invalid"
unit "an auto-name that collides with a command is disambiguated" \
     "ca.slug('list@example.com')" "list-acct"
unit "an auto-name keeps a normal address intact" \
     "ca.slug('Some.Body+tag@example.com')" "some.body-tag"
unit "column widths ignore colour escapes" \
     "ca.visible_len('\033[32mabc\033[0m')" "3"

# --- 14. the pre-1.2.0 environment variable names still work ------------------
seed
out="$(env -u CLAUDE_HOP_OFFLINE -u CLAUDE_HOP_BACKEND \
       CLAUDE_ACCT_OFFLINE=1 CLAUDE_ACCT_BACKEND=file "$HOP" doctor --json 2>/dev/null)"
is "legacy CLAUDE_ACCT_BACKEND is honoured" \
   "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["backend"])')" "file"

# --- 15. install.sh upgrades a claude-acct install in place -------------------
rc="$TMP/rc"
printf 'export FOO=1\n\n# Claude Code account switcher — `claude-acct`\n[ -f "$HOME/.claude/claude-acct.sh" ] && source "$HOME/.claude/claude-acct.sh"\n\nexport BAR=2\n' > "$rc"
mkdir -p "$TMP/cfg/bin"; touch "$TMP/cfg/bin/claude-acct" "$TMP/cfg/claude-acct.sh"
CLAUDE_CONFIG_DIR="$TMP/cfg" "$ROOT/install.sh" --rc "$rc" >/dev/null 2>&1
is "upgrade leaves exactly one source line" "$(grep -c 'claudehop.sh' "$rc")" "1"
[ ! -e "$TMP/cfg/bin/claude-acct" ] && [ ! -e "$TMP/cfg/claude-acct.sh" ] \
  && ok "upgrade removes the old binary and glue" || bad "upgrade removes the old binary and glue" "$(ls "$TMP/cfg/bin" "$TMP/cfg")"
grep -q 'claude-acct' "$rc" && bad "upgrade refreshes the stale comment" "$(grep claude-acct "$rc")" \
  || ok "upgrade refreshes the stale comment"
is "upgrade keeps the user's own lines" "$(grep -c 'export BAR=2' "$rc")" "1"
CLAUDE_CONFIG_DIR="$TMP/cfg" "$ROOT/install.sh" --uninstall --rc "$rc" >/dev/null 2>&1
is "uninstall removes our line"  "$(grep -c 'claudehop' "$rc")" "0"
is "uninstall keeps the rest"    "$(grep -c 'export' "$rc")" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
