#!/usr/bin/env bash
# Exercises claudehop against a throwaway config dir with fake credentials.
# No network, no real Claude account, nothing outside $TMP is touched.
#
#   ./test/test-switch.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOP="$ROOT/claudehop.py"
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
               "savedAt": "2026-01-02T03:04:05+0900",
               "claudeAiOauth": {"accessToken": t, "refreshToken": "r-" + n,
                                 "expiresAt": 99999999999999}},
              open(f"{d}/{n}.json", "w"))
PY
  chmod 600 "$CLAUDE_ACCOUNTS_DIR"/*.json
  echo alpha > "$CLAUDE_ACCOUNTS_DIR/active"
}

# Edit one field of a saved account's oauth block. For whichever account is
# active, the credential store is what the tool believes - Claude Code rewrites
# it every few hours - so a fixture that only touches the saved copy is not a
# state this tool can ever be in. Mirror it into the store as well.
poke() {  # poke <name> <field> <python expression>
  CH_N="$1" CH_F="$2" CH_V="$3" python3 - <<'PY'
import json, os, time  # noqa: F401  (time is for the caller's expression)
n, f = os.environ['CH_N'], os.environ['CH_F']
v = eval(os.environ['CH_V'])
d = os.environ['CLAUDE_ACCOUNTS_DIR']
prof = f"{d}/{n}.json"
p = json.load(open(prof))
p['claudeAiOauth'][f] = v
json.dump(p, open(prof, "w"))
if os.path.exists(f"{d}/active") and open(f"{d}/active").read().strip() == n:
    c = os.environ['CLAUDE_CONFIG_DIR'] + "/.credentials.json"
    doc = json.load(open(c))
    if doc.get('claudeAiOauth'):
        doc['claudeAiOauth'][f] = v
        json.dump(doc, open(c, "w"))
PY
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

# --- 2b. hopping to the account you are already on, after a rotation ----------
# The saved copy is stale and the live token is the newer one. Loading the saved
# block and writing it back put the spent refresh token into the live store, and
# every further run flipped them again, so one run is the sharper check.
seed
python3 -c "
import json,os
p=os.environ['CLAUDE_CONFIG_DIR']+'/.credentials.json'; d=json.load(open(p))
d['claudeAiOauth']['accessToken']='tok-A-refreshed'; d['claudeAiOauth']['refreshToken']='r-A-refreshed'
json.dump(d,open(p,'w'))"
"$HOP" use alpha >/dev/null 2>&1
is "hopping to the current account keeps the rotated token"   "$(live_token)" "tok-A-refreshed"
is "...and its refresh token"  "$(jget "$TMP/.credentials.json" claudeAiOauth.refreshToken)" "r-A-refreshed"
is "...and brings the saved copy up to date"  "$(saved_token alpha)" "tok-A-refreshed"
is "...and keeps the mcpOAuth block"  "$(jget "$TMP/.credentials.json" 'mcpOAuth.vercel|x.accessToken')" "vca_KEEPME"

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
# knocked every later column out of line. The coloured cell lives in --long.
seed                                    # two rows, both with the same savedAt
poke alpha expiresAt 1000
strip_ansi() { python3 -c 'import re,sys;sys.stdout.write(re.sub("\033\\[[0-9;]*m","",sys.stdin.read()))'; }
saved_cols() {  # column where the SAVED cell starts, one number per data row
  # NO_COLOR is exported for the whole suite and _use_color() checks it before
  # CLICOLOR_FORCE, so it has to come off here or there is no colour to test.
  env -u NO_COLOR CLICOLOR_FORCE=1 "$HOP" list --long 2>/dev/null \
    | strip_ansi | tail -n +2 \
    | awk '{print match($0, /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)}' | sort -u | tr '\n' ' '
}
[ "$(saved_cols | wc -w)" -eq 1 ] \
  && ok "columns line up even with colour in a cell" \
  || bad "columns line up even with colour in a cell" "SAVED starts at columns: $(saved_cols)"
env -u NO_COLOR CLICOLOR_FORCE=1 "$HOP" list --long 2>/dev/null | grep -q 'expired' \
  && ok "an expired token is called out" || bad "an expired token is called out" "no 'expired' in --long"
"$HOP" list 2>/dev/null | grep -q 'expired' \
  && bad "the plain listing stays free of token bookkeeping" "'expired' leaked into the default view" \
  || ok "the plain listing stays free of token bookkeeping"

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

# --- 12. `add` never leaves you logged out, and never loses a login ----------
# `add` clears the live credentials before handing you to `claude` for /login.
# If that produces nothing — no `claude`, an immediate exit, Ctrl-C — the old
# credentials must come back. If it DOES produce a login, that login must reach
# disk even when the process is being torn down. Driven in-process: it needs a
# tty and a `claude`, and faking both with a pty hangs on some platforms.
add_with() {  # add_with <python body for the fake `claude` run> [name] [identity dict]
  HOP="$HOP" FAKE_CLAUDE="$1" ADD_NAME="${2:-gamma}" FAKE_IDENT="${3:-}" python3 - <<'PY' >/dev/null 2>&1
import importlib.machinery, importlib.util, json, os, sys

loader = importlib.machinery.SourceFileLoader("ca", os.environ["HOP"])
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", loader))
loader.exec_module(ca)

class Tty:                      # cmd_add insists on a real terminal
    def isatty(self):
        return True
sys.stdin = Tty()
ca.shutil.which = lambda cmd: "/bin/true"
ca.subprocess.call = lambda *a, **k: exec(
    os.environ["FAKE_CLAUDE"], {"ca": ca, "json": json}
)
if os.environ["FAKE_IDENT"]:
    # The suite runs offline, so identity() normally answers "not checked".
    # Some paths need it to name an account.
    ident = json.loads(os.environ["FAKE_IDENT"])
    ca.identity = lambda blk: dict(ident)
try:
    ca.cmd_add(name=os.environ["ADD_NAME"], yes=True)
except BaseException:           # incl. the simulated teardown signals
    pass
PY
}

login_new='ca.set_live_oauth({"accessToken": "tok-NEW", "expiresAt": 99999999999999})'

seed
add_with 'pass'                                  # `claude` exits, nobody logs in
is "a failed add restores the previous login" "$(live_token)" "tok-A"
[ ! -e "$CLAUDE_ACCOUNTS_DIR/gamma.json" ] \
  && ok "a failed add saves no profile" || bad "a failed add saves no profile" "gamma.json exists"

seed
add_with 'raise KeyboardInterrupt'               # torn down before logging in
is "an interrupted add restores the previous login" "$(live_token)" "tok-A"

seed
add_with "$login_new"
is "a real login is saved under the new name" "$(saved_token gamma)" "tok-NEW"
is "the new account becomes active"           "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "gamma"
is "the account we were on was saved first"   "$(saved_token alpha)" "tok-A"

# The bug this section exists for: the login had already happened, and the save
# sat outside the cleanup path, so a Ctrl-C or a closed terminal threw it away.
seed
add_with "$login_new; raise KeyboardInterrupt"
is "a login is saved even if we are interrupted after it" "$(saved_token gamma)" "tok-NEW"
is "...and the new account is still marked active" "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "gamma"

seed
add_with "$login_new; raise ca._TerminalGone(1)"   # SIGHUP: terminal closed
is "a login survives the terminal closing" "$(saved_token gamma)" "tok-NEW"

# Replacing an existing profile must not damage it when the login fails, and
# must not leave the old account's email attached to a new account's token.
seed
add_with 'pass' beta
is "a failed replace leaves the old profile alone" "$(saved_token beta)" "tok-B"
seed
add_with "$login_new" beta
is "a replace stores the new token"      "$(saved_token beta)" "tok-NEW"
is "a replace drops the stale email"     "$(jget "$CLAUDE_ACCOUNTS_DIR/beta.json" email)" "None"

# A claude session that was already running can refresh the PREVIOUS account's
# token into the store while we wait. That is not a new login, and filing it
# under the new name would label alpha's live credential as 'gamma'.
seed
add_with 'ca.set_live_oauth({"accessToken": "tok-A-refreshed", "expiresAt": 99999999999999})' \
         gamma '{"accountUuid": "uuid-A", "email": "alpha@x.com", "tokenState": "ok"}'
[ ! -e "$CLAUDE_ACCOUNTS_DIR/gamma.json" ] \
  && ok "a refresh race is not saved as a new account" \
  || bad "a refresh race is not saved as a new account" "gamma.json exists"
is "a refresh race is filed under the right account" "$(saved_token alpha)" "tok-A-refreshed"
is "a refresh race leaves that account active" "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "alpha"

# ...but re-adding the SAME account under its own name is legitimate.
seed
add_with 'ca.set_live_oauth({"accessToken": "tok-A-refreshed", "expiresAt": 99999999999999})' \
         alpha '{"accountUuid": "uuid-A", "email": "alpha@x.com", "tokenState": "ok"}'
is "re-adding the same account under its own name works" "$(saved_token alpha)" "tok-A-refreshed"

# --- 12b. the child must not inherit our signal handling ---------------------
# The parent stops reacting to SIGINT while `claude` runs (in Claude Code Ctrl-C
# cancels a turn, it does not quit, so unwinding on the first one is wrong). If
# that were done with SIG_IGN it would survive exec and `claude` itself would go
# deaf to Ctrl-C. Run a real child and read its actual signal mask.
if [ -r /proc/self/status ]; then
  cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env python3
import json, os, re
status = open("/proc/self/status").read()
ign = int(re.search(r"^SigIgn:\s*([0-9a-f]+)", status, re.M).group(1), 16)
open(os.environ["SIGREPORT"], "w").write(str(ign))
json.dump({"claudeAiOauth": {"accessToken": "tok-NEW", "expiresAt": 99999999999999}},
          open(os.environ["CLAUDE_CONFIG_DIR"] + "/.credentials.json", "w"))
FAKE
  chmod +x "$TMP/bin/claude"
  seed
  SIGREPORT="$TMP/sigign" PATH="$TMP/bin:$PATH" HOP="$HOP" python3 - <<'PY' >/dev/null 2>&1
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("ca", os.environ["HOP"])
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", loader))
loader.exec_module(ca)
class Tty:
    def isatty(self):
        return True
sys.stdin = Tty()
try:
    ca.cmd_add(name="gamma", yes=True)
except SystemExit:
    pass
PY
  sigign="$(cat "$TMP/sigign" 2>/dev/null || echo missing)"
  if [ "$sigign" = missing ]; then
    bad "the child reports its signal mask" "fake claude never ran"
  else
    [ $(( sigign & 2 )) -eq 0 ] \
      && ok "the child still sees Ctrl-C (SIGINT not inherited as ignored)" \
      || bad "the child still sees Ctrl-C" "SigIgn=$sigign has SIGINT set"
    [ $(( sigign & 1 )) -eq 0 ] \
      && ok "the child still sees SIGHUP" \
      || bad "the child still sees SIGHUP" "SigIgn=$sigign has SIGHUP set"
  fi
  is "a login through a real child is saved" "$(saved_token gamma)" "tok-NEW"
  rm -f "$TMP/bin/claude"
fi

# --- 12c. `add` refuses to run alongside a live session ----------------------
# A running session rewrites the credential store on its own schedule, so the
# only reliable answer is not to start. It must refuse before clearing anything.
guarded_add() {  # guarded_add <yes>
  HOP="$HOP" ADD_YES="$1" python3 - <<'PY' >/dev/null 2>&1
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("ca", os.environ["HOP"])
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", loader))
loader.exec_module(ca)
class Tty:
    def isatty(self):
        return True
sys.stdin = Tty()
ca.shutil.which = lambda cmd: "/bin/true"
ca.running_claude_pids = lambda: [4242]
ca.subprocess.call = lambda *a, **k: ca.set_live_oauth(
    {"accessToken": "tok-NEW", "expiresAt": 99999999999999})
try:
    ca.cmd_add(name="gamma", yes=os.environ["ADD_YES"] == "yes")
except BaseException:
    pass
PY
}

seed
guarded_add no
is "add refuses while a claude session is running" "$(live_token)" "tok-A"
[ ! -e "$CLAUDE_ACCOUNTS_DIR/gamma.json" ] \
  && ok "a refused add writes nothing" || bad "a refused add writes nothing" "gamma.json exists"
seed
guarded_add yes
is "--yes overrides the running-session stop" "$(saved_token gamma)" "tok-NEW"

# --- 12d. bare `hop` picks an account ----------------------------------------
# The everyday path: run it with no arguments, answer the prompt.
pick_with() {  # pick_with <what the user types at the prompt>
  HOP="$HOP" ANSWER="$1" python3 - <<'PY' >/dev/null 2>&1
import builtins, importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("ca", os.environ["HOP"])
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", loader))
loader.exec_module(ca)
class Tty:                      # cmd_pick only prompts on a terminal
    def isatty(self):
        return True
    def write(self, s):
        return len(s)
    def flush(self):
        pass
sys.stdin = sys.stdout = Tty()
builtins.input = lambda prompt="": os.environ["ANSWER"]
try:
    ca.cmd_pick(yes=True)
except SystemExit:
    pass
PY
}

seed                                   # accounts sort alpha, beta; alpha active
pick_with 2
is "picking a number switches"        "$(live_token)" "tok-B"
is "picking a number moves the pointer" "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "beta"

seed
pick_with ''
is "Enter at the prompt stays put"    "$(live_token)" "tok-A"

seed
pick_with bet                          # a name, or enough of one
is "picking by name prefix switches"  "$(live_token)" "tok-B"

seed
pick_with 9
is "an out-of-range pick changes nothing" "$(live_token)" "tok-A"

# Nobody is there to answer a prompt in a pipe, so it stays a listing.
seed
out="$("$HOP" 2>/dev/null)"
printf '%s' "$out" | grep -q 'NAME' \
  && ok "bare hop in a pipe still lists" || bad "bare hop in a pipe still lists" "no table: $out"
printf '%s' "$out" | grep -qi 'which' \
  && bad "bare hop in a pipe does not prompt" "prompted anyway" \
  || ok "bare hop in a pipe does not prompt"
is "bare hop in a pipe switches nothing" "$(live_token)" "tok-A"

# --- 12e. the re-login plan ---------------------------------------------------
# Refresh windows are ~30 days from the login that issued them and do not slide,
# so with several accounts the dates drift apart. doctor should name the earliest
# and say to do them all that day, which resets every window to the same date.
seed
poke alpha refreshTokenExpiresAt "int((time.time() + 3 * 86400) * 1000)"
poke beta  refreshTokenExpiresAt "int((time.time() + 20 * 86400) * 1000)"
out="$("$HOP" doctor 2>/dev/null)"
case "$out" in *"re-login     by"*) ok "doctor prints a re-login date" ;;
              *) bad "doctor prints a re-login date" "$out" ;; esac
case "$out" in *"(alpha)"*) ok "doctor names the account that expires first" ;;
              *) bad "doctor names the account that expires first" "$out" ;; esac
case "$out" in *"collapse them to one date"*|*"collapse to one date"*)
                ok "doctor says to batch the re-logins" ;;
              *) bad "doctor says to batch the re-logins" "$out" ;; esac
case "$out" in *"alpha: refresh token expires in "*)
                ok "an account inside the notice window is warned about" ;;
              *) bad "an account inside the notice window is warned about" "$out" ;; esac
case "$out" in *"beta: refresh token expires"*)
                bad "an account 20d out is not warned about yet" "warned too early" ;;
              *) ok "an account 20d out is not warned about yet" ;; esac
is "the plan is in --json" \
   "$("$HOP" doctor --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["reloginPlan"]["firstAccounts"][0])')" \
   "alpha"

# One account, or dates within a day of each other, means nothing to batch.
seed
poke alpha refreshTokenExpiresAt "int((time.time() + 20 * 86400) * 1000)"
poke beta  refreshTokenExpiresAt "int((time.time() + 20 * 86400) * 1000)"
out="$("$HOP" doctor 2>/dev/null)"
case "$out" in *"collapse"*) bad "no batching advice when the dates already match" "$out" ;;
              *) ok "no batching advice when the dates already match" ;; esac

# An already-dead refresh token needs a real login, not a batching suggestion.
seed
poke alpha refreshTokenExpiresAt "int((time.time() - 86400) * 1000)"
out="$("$HOP" doctor 2>/dev/null)"
case "$out" in *"expired: alpha"*) ok "doctor calls out a dead refresh token" ;;
              *) bad "doctor calls out a dead refresh token" "$out" ;; esac

# --- 12f. the active account is judged by the live login ----------------------
# A saved profile is a snapshot from the last hop or sync. Claude Code rotates
# the live token behind it and a browser re-login replaces it outright, so for
# the active account the credential store is newer by definition. Reading the
# snapshot instead is how a working login gets reported as expired.
seed
python3 - <<'PY'
import json, os, time
d = os.environ['CLAUDE_ACCOUNTS_DIR']
p = json.load(open(f"{d}/alpha.json"))
p['claudeAiOauth']['accessToken'] = 'tok-A-old'
p['claudeAiOauth']['expiresAt'] = 1000
p['claudeAiOauth']['refreshTokenExpiresAt'] = int((time.time() - 86400) * 1000)
json.dump(p, open(f"{d}/alpha.json", "w"))
PY
out="$(env -u NO_COLOR CLICOLOR_FORCE=1 "$HOP" list --long 2>/dev/null | strip_ansi)"
case "$out" in *expired*) bad "the live login beats a stale snapshot" "$out" ;;
              *) ok "the live login beats a stale snapshot" ;; esac
out="$("$HOP" doctor 2>/dev/null)"
case "$out" in *"alpha: refresh token expired"*)
                bad "a live account is not called dead" "$out" ;;
              *) ok "a live account is not called dead" ;; esac
case "$out" in *"'alpha' saved copy is behind"*) ok "doctor spots the stale snapshot" ;;
              *) bad "doctor spots the stale snapshot" "$out" ;; esac
case "$out" in *"'beta' saved copy is behind"*)
                bad "only the active account is compared to the store" "$out" ;;
              *) ok "only the active account is compared to the store" ;; esac
"$HOP" doctor --fix >/dev/null 2>&1
is "doctor --fix syncs the stale snapshot" \
   "$(jget "$CLAUDE_ACCOUNTS_DIR/alpha.json" 'claudeAiOauth.accessToken')" "tok-A"

# --- 12g. renew ---------------------------------------------------------------
# The suite runs with CLAUDE_HOP_OFFLINE=1, so renew has to refuse rather than
# reach for the network - and refuse without touching anything.
seed
out="$("$HOP" renew 2>&1)"; rc=$?
is "renew exits non-zero when offline"      "$rc" "1"
case "$out" in *offline*) ok "renew says why it refused" ;;
              *) bad "renew says why it refused" "$out" ;; esac
is "renew leaves the credential store alone" "$(live_token)" "tok-A"
is "renew leaves the saved copy alone" \
   "$(jget "$CLAUDE_ACCOUNTS_DIR/alpha.json" 'claudeAiOauth.accessToken')" "tok-A"

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

# --- 16. shell-init, and the glue it has to agree with ------------------------
init="$("$HOP" shell-init 2>/dev/null)"
printf '%s' "$init" | bash -n - && ok "shell-init emits valid bash" || bad "shell-init emits valid bash" "$init"
printf '%s' "$init" | grep -q "complete -F _claudehop_complete" \
  && ok "shell-init wires up completion" || bad "shell-init wires up completion" "$init"
printf '%s' "$init" | grep -q 'PATH' \
  && bad "shell-init leaves PATH alone" "pip already put it there" || ok "shell-init leaves PATH alone"
# The sourced glue keeps its own hand-written verb list. Drift between the two
# is invisible until someone tabs for a command that is missing from one of them.
missing="$(HOP="$HOP" ROOT="$ROOT" python3 - <<'PY'
import os, re, subprocess
init = subprocess.run([os.environ["HOP"], "shell-init"], capture_output=True, text=True).stdout
glue = open(os.path.join(os.environ["ROOT"], "shell", "claudehop.sh")).read()
emitted = set(re.search(r'compgen -W "([^"$]*)', init).group(1).split())
declared = set(re.search(r"_claudehop_verbs='([^']*)'", glue).group(1).split())
print(" ".join(sorted(emitted ^ declared)))
PY
)"
is "the sourced glue completes the same verbs" "$missing" ""

# --- 17. providers: run claude through another command, not a saved login ------
seed
OLD_PATH="$PATH"
mkdir -p "$TMP/pbin"
printf '#!/usr/bin/env bash\necho "fake-bedrock: $*"\n' > "$TMP/pbin/fake-bedrock"
printf '#!/usr/bin/env bash\necho "real-claude: $*"\n' > "$TMP/pbin/claude"
chmod +x "$TMP/pbin/fake-bedrock" "$TMP/pbin/claude"
export PATH="$TMP/pbin:$PATH"
PF="$CLAUDE_ACCOUNTS_DIR/provider"

out="$("$HOP" provider bedrock fake-bedrock 2>&1)"
printf '%s' "$out" | grep -q "registered provider bedrock" && ok "provider registers a command" || bad "provider registers a command" "$out"
is "the provider file holds only the command" "$(cat "$CLAUDE_ACCOUNTS_DIR/bedrock.provider")" "fake-bedrock"
is "the provider file is private" "$(python3 -c 'import os,sys;print(format(os.stat(sys.argv[1]).st_mode & 0o777,"o"))' "$CLAUDE_ACCOUNTS_DIR/bedrock.provider")" "600"
"$HOP" provider alpha fake-bedrock >/dev/null 2>&1 && bad "a provider cannot take an account's name" "accepted" || ok "a provider cannot take an account's name"
"$HOP" provider list fake-bedrock >/dev/null 2>&1 && bad "a provider cannot take a command's name" "accepted" || ok "a provider cannot take a command's name"
"$HOP" provider two "fake-bedrock --x" >/dev/null 2>&1 && bad "a provider command is one word" "accepted" || ok "a provider command is one word"

"$HOP" bedrock >/dev/null 2>&1
is "hop <provider> writes the pointer" "$(cat "$PF" 2>/dev/null)" "bedrock"
is "a provider leaves the live login alone" "$(live_token)" "tok-A"
is "a provider leaves the account pointer alone" "$(cat "$CLAUDE_ACCOUNTS_DIR/active")" "alpha"
is "active names the provider" "$("$HOP" active)" "bedrock"
"$HOP" active --json | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d["provider"]=="bedrock" and d["active"]=="alpha" else 1)' \
  && ok "active --json carries the provider and the account" || bad "active --json carries the provider and the account" "$("$HOP" active --json)"
"$HOP" list --json | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d["provider"]=="bedrock" and d["providers"][0]["active"] and d["providers"][0]["command"]=="fake-bedrock" else 1)' \
  && ok "list --json lists the provider" || bad "list --json lists the provider" "$("$HOP" list --json)"
tbl="$("$HOP" list)"
printf '%s\n' "$tbl" | grep -qE '^\* +bedrock +runs fake-bedrock +provider' && ok "list stars the provider" || bad "list stars the provider" "$tbl"
printf '%s\n' "$tbl" | grep -qE '^\* +alpha' && bad "list unstars the account while a provider is on" "$tbl" || ok "list unstars the account while a provider is on"
is "hop use <provider> is the long spelling" "$("$HOP" use bedrock 2>&1 | grep -c 'already on')" "1"

# The shell function is what actually reroutes `claude`.
glue() { bash -c 'source "$1"; shift; "$@"' _ "$ROOT/shell/claudehop.sh" "$@"; }
is "claude runs through the provider while it is on" "$(glue claude hello 2>&1)" "fake-bedrock: hello"
glue _claudehop_names | grep -qw bedrock && ok "completion offers provider names" || bad "completion offers provider names" "$(glue _claudehop_names)"

out="$("$HOP" off 2>&1)"
printf '%s' "$out" | grep -q "left bedrock" && ok "off leaves the provider" || bad "off leaves the provider" "$out"
[ ! -e "$PF" ] && ok "off removes the pointer" || bad "off removes the pointer" "still there"
is "claude runs normally after off" "$(glue claude hello 2>&1)" "real-claude: hello"
is "off with nothing on says so" "$("$HOP" off 2>&1)" "no provider is on"

"$HOP" bedrock >/dev/null 2>&1
out="$("$HOP" alpha 2>&1)"
printf '%s' "$out" | grep -q "left bedrock" && ok "hopping to the live account leaves the provider" || bad "hopping to the live account leaves the provider" "$out"
[ ! -e "$PF" ] && ok "...and removes the pointer" || bad "...and removes the pointer" "still there"
"$HOP" bedrock >/dev/null 2>&1
"$HOP" beta >/dev/null 2>&1
[ ! -e "$PF" ] && is "hopping to another account leaves the provider and switches" "$(live_token)" "tok-B" \
  || bad "hopping to another account leaves the provider and switches" "pointer still there"

printf 'no-such-command-xyz\n' > "$CLAUDE_ACCOUNTS_DIR/ghost.provider"; chmod 600 "$CLAUDE_ACCOUNTS_DIR/ghost.provider"
"$HOP" ghost >/dev/null 2>&1 && bad "a provider whose command is missing is refused" "accepted" || ok "a provider whose command is missing is refused"
[ ! -e "$PF" ] && ok "...and no pointer is written" || bad "...and no pointer is written" "$(cat "$PF")"
echo ghost > "$PF"
err="$(glue claude hi 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q "was not found" && ok "claude warns when the provider command has gone" || bad "claude warns when the provider command has gone" "$err"
is "...and still starts claude normally" "$(glue claude hi 2>/dev/null)" "real-claude: hi"
"$HOP" doctor 2>&1 | grep -q "no-such-command-xyz" && ok "doctor flags a provider whose command is missing" || bad "doctor flags a provider whose command is missing" "$("$HOP" doctor 2>&1)"
rm -f "$CLAUDE_ACCOUNTS_DIR/ghost.provider"
"$HOP" doctor >/dev/null 2>&1 && bad "doctor fails on a pointer to a missing provider" "exit 0" || ok "doctor fails on a pointer to a missing provider"
"$HOP" doctor --fix >/dev/null 2>&1
[ ! -e "$PF" ] && ok "doctor --fix clears the dangling pointer" || bad "doctor --fix clears the dangling pointer" "$(cat "$PF")"

"$HOP" bedrock >/dev/null 2>&1
"$HOP" rm bedrock -y >/dev/null 2>&1
[ ! -e "$CLAUDE_ACCOUNTS_DIR/bedrock.provider" ] && [ ! -e "$PF" ] && ok "rm deletes a provider and its pointer" || bad "rm deletes a provider and its pointer" "$(ls "$CLAUDE_ACCOUNTS_DIR")"
is "rm on a provider leaves the accounts" "$(ls "$CLAUDE_ACCOUNTS_DIR"/*.json | wc -l | tr -d ' ')" "2"
export PATH="$OLD_PATH"

# --- 18. names that would hide something are refused ---------------------------
seed
out="$("$HOP" rename beta list 2>&1)"
[ -e "$CLAUDE_ACCOUNTS_DIR/list.json" ] && bad "rename refuses a command's name" "created list.json" \
  || ok "rename refuses a command's name"
printf '%s' "$out" | grep -q "command" && ok "...and says why" || bad "...and says why" "$out"
printf '#!/bin/sh\n' > "$TMP/bin/launcher"; chmod +x "$TMP/bin/launcher"
OLD_PATH="$PATH"; export PATH="$TMP/bin:$PATH"
"$HOP" provider bedrock launcher >/dev/null 2>&1
"$HOP" rename beta bedrock >/dev/null 2>&1
[ -e "$CLAUDE_ACCOUNTS_DIR/bedrock.json" ] && bad "rename refuses a provider's name" "created bedrock.json" \
  || ok "rename refuses a provider's name"
"$HOP" save list -y >/dev/null 2>&1
[ -e "$CLAUDE_ACCOUNTS_DIR/list.json" ] && bad "save refuses a command's name" "created list.json" \
  || ok "save refuses a command's name"
export PATH="$OLD_PATH"
# an account that already has such a name keeps working (it predates the check)
cp "$CLAUDE_ACCOUNTS_DIR/beta.json" "$CLAUDE_ACCOUNTS_DIR/check.json"
"$HOP" use check >/dev/null 2>&1 && is "an existing account with a command's name can still be used" "$(live_token)" "tok-B" \
  || bad "an existing account with a command's name can still be used" "use failed"

# --- 19. doctor survives a profile it cannot parse -----------------------------
seed
printf '{"claudeAiOauth": {"acc' > "$CLAUDE_ACCOUNTS_DIR/beta.json"
chmod 600 "$CLAUDE_ACCOUNTS_DIR/beta.json"
out="$("$HOP" doctor 2>&1)"; rc=$?
printf '%s' "$out" | grep -q "beta.json is empty or not valid JSON" && ok "doctor names the profile it cannot read" \
  || bad "doctor names the profile it cannot read" "$out"
[ "$rc" -eq 1 ] && ok "...and exits non-zero" || bad "...and exits non-zero" "rc=$rc"
printf '%s' "$out" | grep -q "no problems found" && bad "...and does not call it healthy" "$out" || ok "...and does not call it healthy"
is "the live account is still found past the broken profile" "$("$HOP" active 2>/dev/null)" "alpha"

# --- 20. we keep out of Claude Code's token refresh ----------------------------
# While it refreshes, Claude Code holds two directories as locks, takes the login
# out of the store, calls the token endpoint and writes the result back. A switch
# inside that window is overwritten by the old account's refreshed token. We hold
# the same two, in its order, while we read and replace the login. Behaviour of
# Claude Code itself was checked against 2.1.284 by tracing it in a sandbox.
PRIMARY="$TMP/.oauth_refresh.lock"; LEGACY="$TMP.lock"
hold() {  # hold <seconds> <dir>...  the way Claude Code does: mkdir, wait, rmdir
  python3 -c "
import os, sys, time
for d in sys.argv[2:]: os.mkdir(d)
time.sleep(float(sys.argv[1]))
for d in reversed(sys.argv[2:]): os.rmdir(d)" "$@" &
  HOLDER=$!
  for _ in $(seq 50); do [ -d "${*: -1}" ] && break; sleep 0.1; done
}
export CLAUDE_HOP_LOCK_WAIT=1
age_by() {  # age_by <seconds> <path>...  (BSD touch has no relative -d)
  python3 -c "
import os, sys, time
t = time.time() - float(sys.argv[1])
for p in sys.argv[2:]: os.utime(p, (t, t))" "$@"
}

seed
"$HOP" use beta >/dev/null 2>&1
[ ! -e "$PRIMARY" ] && [ ! -e "$LEGACY" ] && ok "a switch leaves no lock behind" \
  || bad "a switch leaves no lock behind" "$(ls -d "$PRIMARY" "$LEGACY" 2>&1)"

seed
hold 3 "$PRIMARY"
out="$("$HOP" use beta 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a switch waits for Claude Code's refresh lock, then stops" || bad "a switch waits for Claude Code's refresh lock, then stops" "rc=0"
is "...and changes nothing"  "$(live_token)" "tok-A"
printf '%s' "$out" | grep -q "refreshing" && ok "...and says why" || bad "...and says why" "$out"
wait "$HOLDER"
"$HOP" use beta >/dev/null 2>&1
is "...and works once the lock is free"  "$(live_token)" "tok-B"

seed
hold 3 "$LEGACY"
"$HOP" use beta >/dev/null 2>&1 && bad "the legacy lock holds a switch off too" "rc=0" || ok "the legacy lock holds a switch off too"
[ ! -e "$PRIMARY" ] && ok "...and we let go of the first lock, as Claude Code does" \
  || bad "...and we let go of the first lock, as Claude Code does" "left $PRIMARY behind"
wait "$HOLDER"

seed
mkdir "$PRIMARY" "$LEGACY"; age_by 120 "$PRIMARY" "$LEGACY"
"$HOP" use beta >/dev/null 2>&1
is "a lock nobody has touched for 60s is taken over"  "$(live_token)" "tok-B"
[ ! -e "$PRIMARY" ] && [ ! -e "$LEGACY" ] && ok "...and released afterwards" || bad "...and released afterwards" "still there"

seed
hold 3 "$PRIMARY"
add_with 'pass'
is "add stops before logging you out when Claude Code holds the lock"  "$(live_token)" "tok-A"
wait "$HOLDER"

seed
mkdir "$PRIMARY"; age_by 300 "$PRIMARY"
"$HOP" doctor 2>&1 | grep -q "stale lock" && ok "doctor reports a lock nobody has touched for minutes" \
  || bad "doctor reports a lock nobody has touched for minutes" "$("$HOP" doctor 2>&1)"
"$HOP" doctor --fix >/dev/null 2>&1
[ ! -e "$PRIMARY" ] && ok "doctor --fix removes it" || bad "doctor --fix removes it" "still there"
mkdir "$PRIMARY"
"$HOP" doctor 2>&1 | grep -q "stale lock" && bad "doctor leaves a fresh lock alone" "reported it" || ok "doctor leaves a fresh lock alone"
rmdir "$PRIMARY"
unset CLAUDE_HOP_LOCK_WAIT

# --- 21. usage: where each account stands against its limits --------------------
# Driven in-process with a fake endpoint. The real one budgets requests from
# clients that are not Claude Code, so the command asks only when run, remembers
# the last good reading, and waits out a Retry-After.
usage_run() {  # usage_run <python that defines `responses`> [json] [name]
  HOP="$HOP" RESPONSES="$1" AS_JSON="${2:-}" ONLY="${3:-}" python3 - <<'PY'
import importlib.machinery, importlib.util, os, json, datetime
loader = importlib.machinery.SourceFileLoader("ca", os.environ["HOP"])
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", loader))
loader.exec_module(ca)
ca.OFFLINE = os.environ.get("USAGE_OFFLINE") == "1"
def at(**kw):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(**kw)).isoformat()
ns = {"at": at}
exec(os.environ["RESPONSES"], ns)
calls = []
def fake(tok, timeout=0):
    calls.append(tok)
    return ns["responses"][tok]
ca.api_usage = fake
ca.cmd_usage(name=os.environ["ONLY"] or None, as_json=bool(os.environ["AS_JSON"]))
print("CALLS=%d" % len(calls))
PY
}
calls_of() { printf '%s' "$1" | sed -n 's/^CALLS=//p'; }
UC="$CLAUDE_ACCOUNTS_DIR/.usage-cache"
two_ok='responses = {
  "tok-A": (200, {"five_hour": {"utilization": 42.0, "resets_at": at(hours=2, minutes=14, seconds=30)},
                  "seven_day": {"utilization": 18, "resets_at": at(days=3, hours=4, minutes=1)},
                  "seven_day_opus": None, "something_new": 5}, None),
  "tok-B": (200, {"five_hour": {"utilization": 7.4, "resets_at": at(hours=4)},
                  "seven_day": {"utilization": 90, "resets_at": at(days=1)}}, None)}'

seed; rm -f "$UC"
out="$(usage_run "$two_ok")"
printf '%s' "$out" | grep -E "alpha" | grep -q "42%.*resets 2h1[45]m.*18%.*resets 3d4h" \
  && ok "usage shows both windows and when each resets" || bad "usage shows both windows and when each resets" "$out"
printf '%s' "$out" | grep -E "beta" | grep -q "7%.*90%" && ok "...for every saved account" || bad "...for every saved account" "$out"
printf '%s' "$out" | grep -E "^\*" | grep -q alpha && ok "...with the live account starred" || bad "...with the live account starred" "$out"
is "...one request per account" "$(calls_of "$out")" "2"
[ "$(stat -c %a "$UC" 2>/dev/null || stat -f %Lp "$UC")" = "600" ] && ok "the cache is private" || bad "the cache is private" "$(ls -l "$UC")"
grep -qE "tok-A|tok-B" "$UC" && bad "the cache holds no tokens" "found one" || ok "the cache holds no tokens"
"$HOP" list 2>&1 | grep -qi "usage" && bad "list ignores the cache" "listed" || ok "list ignores the cache"

out="$(usage_run "$two_ok")"
is "a reading under a minute old is not asked for again" "$(calls_of "$out")" "0"
printf '%s' "$out" | grep -q "42%" && ok "...and is still shown" || bad "...and is still shown" "$out"

# a 429 is remembered, and the last good reading stays on screen
python3 -c "
import json,os
p=os.environ['CLAUDE_ACCOUNTS_DIR']+'/.usage-cache'; d=json.load(open(p))
for v in d.values(): v['fetchedAt'] -= 600
json.dump(d,open(p,'w'))"
throttled='responses = {"tok-A": (429, {}, 1500.0), "tok-B": (429, {}, 1500.0)}'
out="$(usage_run "$throttled")"
is "a 429 is asked about once per account" "$(calls_of "$out")" "2"
printf '%s' "$out" | grep -E "alpha" | grep -q "42%.*throttled.*2[45]m.*last reading 10m ago" \
  && ok "...the last good reading stays, with its age" || bad "...the last good reading stays, with its age" "$out"
out="$(usage_run "$throttled")"
is "...and nobody asks again before the Retry-After" "$(calls_of "$out")" "0"
printf '%s' "$out" | grep -q "throttled" && ok "...and the table still says why" || bad "...and the table still says why" "$out"

seed; rm -f "$UC"
out="$(usage_run "$throttled")"
printf '%s' "$out" | grep -E "alpha" | grep -q "throttled" \
  && printf '%s' "$out" | grep -E "alpha" | grep -q -- " -  .* - " \
  && ok "a throttled first run shows dashes, not an error" || bad "a throttled first run shows dashes, not an error" "$out"
seed; rm -f "$UC"
usage_run 'responses = {"tok-A": (429, {}, None), "tok-B": (429, {}, None)}' >/dev/null
is "...and a 429 without Retry-After still backs off" "$(calls_of "$(usage_run "$throttled")")" "0"

seed; rm -f "$UC"; poke beta expiresAt "1"
out="$(usage_run "$two_ok")"
is "an aged-out token is not sent" "$(calls_of "$out")" "1"
printf '%s' "$out" | grep -E "beta" | grep -q "aged out" && ok "...and the row says what to do" || bad "...and the row says what to do" "$out"

seed; rm -f "$UC"
out="$(usage_run 'responses = {"tok-A": (401, {}, None), "tok-B": (0, {"error": "x"}, None)}')"
printf '%s' "$out" | grep -E "alpha" | grep -q "rejected" && printf '%s' "$out" | grep -E "beta" | grep -q "could not reach" \
  && ok "a rejected token and an unreachable server read differently" || bad "a rejected token and an unreachable server read differently" "$out"

seed; rm -f "$UC"
out="$(usage_run "$two_ok" json)"
printf '%s' "$out" | sed '/^CALLS=/d' | python3 -c "
import json,sys
d=json.load(sys.stdin)['accounts']
a=[x for x in d if x['name']=='alpha'][0]
assert a['active'] is True and a['windows']['five_hour']['pct']==42.0 and a['note'] is None
assert 'seven_day_opus' not in a['windows'] and 'something_new' not in a['windows']
print('ok')" 2>/dev/null | grep -q ok && ok "--json carries the windows and skips what is not one" || bad "--json carries the windows and skips what is not one" "$out"

seed; rm -f "$UC"
out="$(usage_run "$two_ok" "" beta)"
is "naming an account asks about that one only" "$(calls_of "$out")" "1"
printf '%s' "$out" | grep -q alpha && bad "...and shows only it" "$out" || ok "...and shows only it"
"$HOP" usage nosuch >/dev/null 2>&1 && bad "an unknown account is an error" "exit 0" || ok "an unknown account is an error"

seed; rm -f "$UC"
out="$(USAGE_OFFLINE=1 usage_run "$two_ok")"
is "offline mode makes no request" "$(calls_of "$out")" "0"
printf '%s' "$out" | grep -q "offline" && ok "...and says so" || bad "...and says so" "$out"
seed

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
