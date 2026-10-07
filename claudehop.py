#!/usr/bin/env python3
"""claudehop - hop Claude Code between several Claude accounts.

To switch accounts, run `hop` and pick one. That is the whole tool.

  hop                  show your accounts, pick one to hop to
  hop <name>           hop straight to that one
  hop add <name>       log in as a new account and save it

Claude Code reads its login again before each message, so a hop reaches the
sessions you already have open as well, on their next message.

Not everything is a login. Amazon Bedrock, Vertex or a gateway run Claude Code
from environment variables, so a provider is a command you register once and
then hop to like an account:

  hop provider bedrock claude-bedrock   register: the command runs instead of `claude`
  hop bedrock          new `claude` commands run through it
  hop off              back to the saved login (hopping to an account does too)

A provider leaves every saved login alone. The `claude` function in the shell
glue reads the switch, so it only applies in shells that have the glue loaded.

Now and then:

  hop whoami           who is logged in right now (asks the API)
  hop usage [name]     5-hour and 7-day usage per account (asks the API, remembers the answer)
  hop run <name> [..]  claude as that account in this terminal only; the rest goes to claude
  hop renew [name]     refresh the saved tokens (all of them, or just one)
  hop save <name>      save a login you did by hand, under a name
  hop list --long      token expiry and when each account was saved
  hop rm <name>        delete a saved account (does not log you out)
  hop rename <old> <new>
  hop doctor [--fix]   check the setup, repair what it can
  hop shell-init       shell glue for a pip install: eval "$(claudehop shell-init)"

Flags:

  -y, --yes            never prompt; also overrides the running-session stop
  --verify             check saved tokens against the API
  --no-cache, --fresh  bypass the cache for --verify and usage
  --long               more columns in the listing
  --json               machine-readable output
  --no-color           plain text
  -V, --version        print the version

Also accepted, for scripts and old habits: `use`/`switch` (what `hop <name>`
does), `ls`, `active` (print the active name, no network), `sync` (write the live
login back to its file), `--no-sync`, and the pre-1.2.0 names `claude-acct` and
`cacct`.

How it works: Claude Code keeps the live login under the "claudeAiOauth" key of
its credential store - ~/.claude/.credentials.json on Linux, the login keychain
on macOS. This tool keeps one saved copy of that block per account in
~/.claude/accounts/<name>.json and swaps the active one in and out. Everything
else in the store, including your MCP server logins, is left alone. Email and
plan are re-fetched from the API by Claude Code at startup, so swapping the
credential is the entire job.

About expiry: an access token lasts 8 hours and renews itself. The login behind
it lasts up to about 30 days, and that date is fixed when you log in - renewing
rotates the token but never moves the date, so `hop add <name>` is the only way
to reset it. Log every account back in on the same day and the dates collapse
into one, instead of one surprise logout per account per month.

Environment: CLAUDE_CONFIG_DIR (default ~/.claude), CLAUDE_ACCOUNTS_DIR
(default <config>/accounts), CLAUDE_HOP_BACKEND (auto|file|keychain),
CLAUDE_HOP_OFFLINE=1 to never call the API.
"""

from __future__ import annotations

import binascii
import contextlib
import getpass
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import textwrap
import time

VERSION = "1.7.1"
PROG = "claudehop"


def env(*names: str) -> str | None:
    """First of these environment variables that is set and non-empty.

    The tool was called claude-acct before 1.2.0, so the old CLAUDE_ACCT_*
    names are still honoured everywhere the new ones are.
    """
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    return None


HOME = os.path.expanduser("~")
CLAUDE_DIR = env("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
CREDS = os.path.join(CLAUDE_DIR, ".credentials.json")
ACCOUNTS = env("CLAUDE_ACCOUNTS_DIR") or os.path.join(CLAUDE_DIR, "accounts")
ACTIVE_PTR = os.path.join(ACCOUNTS, "active")
LOCK_PATH = os.path.join(ACCOUNTS, ".lock")
PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"

# Claude Code's own public OAuth client - the same id it puts in the authorize
# URL it opens in your browser. Refreshing a saved token needs it.
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

# What Claude Code calls its keychain item on macOS.
KEYCHAIN_SERVICE = "Claude Code-credentials"

OAUTH_KEY = "claudeAiOauth"
API_TIMEOUT = float(env("CLAUDE_HOP_TIMEOUT", "CLAUDE_ACCT_TIMEOUT") or 10.0)
OFFLINE = bool(env("CLAUDE_HOP_OFFLINE", "CLAUDE_ACCT_OFFLINE"))

# Temp files this tool writes; the second is what versions before 1.2.0 left.
TMP_MARKERS = (".tmp-claudehop", ".tmp-claude-acct")

USAGE_EXIT = 2

_ANSI = re.compile(r"\033\[[0-9;]*m")


def _use_color() -> bool:
    if "--no-color" in sys.argv or os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("CLICOLOR_FORCE"):
        return True
    return sys.stdout.isatty()


BOLD, DIM, GREEN, YELLOW, RED, CYAN, OFF = (
    ("\033[1m", "\033[2m", "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[0m")
    if _use_color()
    else ("", "", "", "", "", "", "")
)


def die(msg: str, code: int = 1):
    print(f"{RED}error:{OFF} {msg}", file=sys.stderr)
    sys.exit(code)


def info(msg: str):
    print(msg, file=sys.stderr)


def visible_len(s: str) -> int:
    """Width of a string once the colour escapes are stripped."""
    return len(_ANSI.sub("", s))


def pad(s: str, width: int) -> str:
    return s + " " * max(0, width - visible_len(s))


# ------------------------------------------------------------------ json files


def read_json(path: str) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as e:
        die(f"{path} is not valid JSON ({e}). Refusing to touch it.")


def write_json_secure(path: str, data: dict, keep_backup: bool = False):
    """Atomic, 0600, fsynced. Optionally keeps a .bak of the previous file."""
    tmp = f"{path}{TMP_MARKERS[0]}.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        if keep_backup and os.path.exists(path):
            shutil.copy2(path, path + ".bak")
            os.chmod(path + ".bak", 0o600)
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


# ------------------------------------------------------------ credential store
#
# Two backends. On Linux the live login is a JSON file; on macOS it is normally
# a generic password in the login keychain, and Claude Code falls back to the
# file when the keychain is unavailable (ssh, no GUI session). We read and write
# whichever one currently holds the login so we never split it across both.


class FileStore:
    name = "file"

    def __init__(self, path: str = CREDS):
        self.path = path
        self.where = path

    def exists(self) -> bool:
        return os.path.exists(self.path)

    def read(self) -> dict:
        return read_json(self.path)

    def write(self, doc: dict):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        write_json_secure(self.path, doc, keep_backup=True)


class KeychainStore:
    """macOS login keychain, the same item Claude Code writes itself."""

    name = "keychain"

    def __init__(self, service: str = KEYCHAIN_SERVICE, account: str | None = None):
        self.service = service
        self.account = account or os.environ.get("USER") or getpass.getuser()
        self.where = f"keychain item {service!r} (account {self.account})"

    def _security(self, args: list[str]) -> tuple[int, str, str]:
        p = subprocess.run(
            ["security", *args],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return p.returncode, p.stdout, p.stderr

    def exists(self) -> bool:
        if not shutil.which("security"):
            return False
        rc, _, _ = self._security(
            ["find-generic-password", "-a", self.account, "-s", self.service]
        )
        return rc == 0

    def read(self) -> dict:
        rc, out, err = self._security(
            ["find-generic-password", "-a", self.account, "-s", self.service, "-w"]
        )
        if rc != 0:
            if "could not be found" in err:
                return {}
            die(f"could not read the keychain item: {err.strip() or f'security exited {rc}'}")
        raw = out.strip()
        if not raw:
            return {}
        # `security` prints the secret as text, but as hex if it is not printable.
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            try:
                return json.loads(binascii.unhexlify(raw).decode())
            except Exception:
                die("the keychain item does not contain the JSON Claude Code expects.")

    def write(self, doc: dict):
        blob = json.dumps(doc).encode()
        rc, _, err = self._security(
            [
                "add-generic-password",
                "-U",  # update in place if it already exists
                "-a", self.account,
                "-s", self.service,
                "-X", binascii.hexlify(blob).decode(),
            ]
        )
        if rc != 0:
            die(f"could not write the keychain item: {err.strip() or f'security exited {rc}'}")


def pick_store():
    want = (env("CLAUDE_HOP_BACKEND", "CLAUDE_ACCT_BACKEND") or "auto").lower()
    file_store = FileStore()
    if want == "file":
        return file_store
    if want == "keychain":
        if not shutil.which("security"):
            die("CLAUDE_HOP_BACKEND=keychain but the `security` command is not available.")
        return KeychainStore()
    if want != "auto":
        die(f"CLAUDE_HOP_BACKEND must be auto, file or keychain (got {want!r})")
    if sys.platform != "darwin" or not shutil.which("security"):
        return file_store
    kc = KeychainStore()
    # Whichever one actually holds a login wins; a stale empty file must not
    # shadow a real keychain login, and vice versa.
    if kc.exists():
        return kc
    if file_store.exists() and file_store.read().get(OAUTH_KEY):
        return file_store
    return kc


STORE = pick_store()


def live_oauth() -> dict | None:
    return STORE.read().get(OAUTH_KEY) or None


def set_live_oauth(block: dict):
    doc = STORE.read()
    doc[OAUTH_KEY] = block
    STORE.write(doc)


def clear_live_oauth():
    doc = STORE.read()
    doc.pop(OAUTH_KEY, None)
    STORE.write(doc)


# ---------------------------------------------------------------------- lock
#
# Two `claudehop` runs at once could interleave read-modify-write on the same
# credential store and lose an account. Cheap to prevent.

try:
    import fcntl
except ImportError:  # pragma: no cover - POSIX only in practice
    fcntl = None


class _Lock:
    def __init__(self, path: str):
        self.path = path
        self.fd = None

    def __enter__(self):
        if fcntl is None:
            return self
        profiles_dir()
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            info(f"{DIM}waiting for another {PROG} to finish...{OFF}")
            fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
            self.fd = None
        return False


def lock():
    return _Lock(LOCK_PATH)


# ---------------------------------------------------- Claude Code's refresh lock
#
# The lock above only keeps two `claudehop` runs apart. Claude Code has its own:
# while it refreshes a token it holds two directories as mutexes (npm's
# proper-lockfile), takes the credential store's contents, calls the token
# endpoint, and writes the result back. A switch that lands inside that window
# is overwritten by the old account's refreshed token, and the profile we just
# saved holds a refresh token the server has already retired.
#
# Checked against Claude Code 2.1.284 by tracing it in a sandbox with the
# network cut off: it takes <config>/.oauth_refresh.lock, then <config>.lock
# (~/.claude.lock by default); if the second is held it releases the first and
# retries about every 2s; it never removes a lock younger than 60s, and it
# waits (six mkdir attempts, then gives up for now) when another tool holds
# either one. So holding both, in its order, while we read and overwrite the
# store keeps its refresh out of the way. Keep the held section to file
# reads and writes; do the network calls first.

CLAUDE_LOCK_STALE_S = 60.0  # Claude Code's `stale: 60000`
CLAUDE_LOCK_WAIT_S = float(env("CLAUDE_HOP_LOCK_WAIT") or 9.0)


def claude_lock_dirs() -> tuple[str, str]:
    return (
        os.path.join(CLAUDE_DIR, ".oauth_refresh.lock"),
        os.path.realpath(CLAUDE_DIR) + ".lock",
    )


def _take_dir(path: str) -> bool:
    """mkdir as a mutex, taking over one whose holder has been silent for 60s."""
    try:
        os.mkdir(path)
        return True
    except FileExistsError:
        pass
    try:
        age = time.time() - os.stat(path).st_mtime
    except FileNotFoundError:
        return False  # released between the mkdir and the stat; try again
    if age > CLAUDE_LOCK_STALE_S:
        try:
            os.rmdir(path)
        except OSError:
            pass
    return False


class claude_lock:  # noqa: N801 - used like a function: `with claude_lock():`
    """Hold Claude Code's token-refresh locks, in its own order.

    If they stay busy past the wait, stop with nothing changed. Pass
    required=False where giving up would leave the user logged out (putting a
    login back after `add` cleared it): that path goes ahead without them.
    """

    def __init__(self, required: bool = True):
        self.required = required
        self.held = False

    def __enter__(self):
        primary, legacy = claude_lock_dirs()
        os.makedirs(CLAUDE_DIR, mode=0o700, exist_ok=True)
        deadline = time.monotonic() + CLAUDE_LOCK_WAIT_S
        while True:
            if _take_dir(primary):
                if _take_dir(legacy):
                    self.held = True
                    return self
                try:
                    os.rmdir(primary)  # Claude Code lets go of the first one too
                except OSError:
                    pass
            if time.monotonic() > deadline:
                if not self.required:
                    return self
                die(
                    "Claude Code is refreshing its login right now, so nothing was changed. "
                    "Try again in a few seconds."
                )
            time.sleep(0.25 + 0.25 * random.random())

    def __exit__(self, *exc):
        if self.held:
            for path in reversed(claude_lock_dirs()):
                try:
                    os.rmdir(path)
                except OSError:
                    pass
            self.held = False
        return False


# ------------------------------------------------------------------- profiles


def profiles_dir() -> str:
    os.makedirs(ACCOUNTS, mode=0o700, exist_ok=True)
    if os.stat(ACCOUNTS).st_mode & 0o077:
        os.chmod(ACCOUNTS, 0o700)
    return ACCOUNTS


def profile_path(name: str) -> str:
    return os.path.join(profiles_dir(), f"{name}.json")


VALID_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def check_name(name: str) -> str:
    if not VALID_NAME.match(name) or name in (".", ".."):
        die(
            f"'{name}' is not a usable account name. Use letters, digits, dot, "
            f"dash or underscore, starting with a letter or digit."
        )
    return name


def check_new_name(name: str) -> str:
    """check_name, plus: a name we are about to create must not hide anything.

    An account called `list` would be unreachable as `hop list` (the command
    wins), and one that shares a provider's name would shadow the provider.
    Names that already exist are left alone so old setups keep working.
    """
    check_name(name)
    if os.path.exists(profile_path(name)):
        return name
    if name in COMMANDS:
        die(f"'{name}' is a {PROG} command, so `{PROG} {name}` could never switch to it. Pick another name.")
    if name in list_providers():
        die(f"'{name}' is already a provider; pick another name.")
    return name


def list_profiles() -> list[str]:
    if not os.path.isdir(ACCOUNTS):
        return []
    return sorted(
        f[:-5] for f in os.listdir(ACCOUNTS) if f.endswith(".json") and not f.startswith(".")
    )


def load_profile(name: str) -> dict:
    p = profile_path(name)
    if not os.path.exists(p):
        known = ", ".join(list_profiles()) or "none saved yet"
        die(f"no saved account called '{name}'. Saved: {known}")
    return read_json(p)


def peek_profile(name: str) -> dict:
    """A profile for code that only looks: one that will not parse reads as empty.

    load_profile stops the command with a clear error, which is right for a hop
    but wrong for `doctor`, whose job is to say what is broken, and for the scan
    that works out which saved account is live.
    """
    try:
        with open(profile_path(name)) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_profile(name: str, block: dict, meta: dict | None = None):
    data = read_json(profile_path(name))
    data.update(meta or {})
    data["name"] = name
    data[OAUTH_KEY] = block
    data["savedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    write_json_secure(profile_path(name), data)


def read_ptr() -> str | None:
    try:
        with open(ACTIVE_PTR) as f:
            ptr = f.read().strip()
    except OSError:
        return None
    return ptr or None


def set_active_ptr(name: str):
    profiles_dir()
    tmp = f"{ACTIVE_PTR}.tmp-{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(name + "\n")
    os.replace(tmp, ACTIVE_PTR)


# --------------------------------------------------------------- providers
#
# A provider is a way of running Claude Code that does not use a saved login at
# all - Amazon Bedrock, Vertex, a gateway. It is one file, <name>.provider, that
# holds the name of a command to run in place of `claude`. Turning one on writes
# its name to the `provider` pointer and leaves every saved login alone; hopping
# to an account (or `hop off`) removes the pointer. The `claude` function in the
# shell glue reads the pointer, so only NEW `claude` commands change.

PROVIDER_PTR = os.path.join(ACCOUNTS, "provider")
PROVIDER_EXT = ".provider"


def provider_path(name: str) -> str:
    return os.path.join(ACCOUNTS, name + PROVIDER_EXT)


def list_providers() -> list[str]:
    try:
        files = os.listdir(ACCOUNTS)
    except OSError:
        return []
    return sorted(f[: -len(PROVIDER_EXT)] for f in files if f.endswith(PROVIDER_EXT))


def provider_command(name: str) -> str | None:
    try:
        with open(provider_path(name)) as f:
            cmd = f.readline().strip()
    except OSError:
        return None
    return cmd or None


def read_provider() -> str | None:
    try:
        with open(PROVIDER_PTR) as f:
            ptr = f.read().strip()
    except OSError:
        return None
    return ptr or None


def set_provider_ptr(name: str):
    profiles_dir()
    tmp = f"{PROVIDER_PTR}.tmp-{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(name + "\n")
    os.replace(tmp, PROVIDER_PTR)


def clear_provider_ptr() -> str | None:
    """Turn any provider off. Returns the name that was on, if any."""
    was = read_provider()
    try:
        os.remove(PROVIDER_PTR)
    except OSError:
        pass
    return was


def active_provider() -> str | None:
    """The provider new sessions will use, or None. A pointer that names a
    provider which no longer exists counts as off, so a deleted file can never
    leave `claude` running a command that is not there."""
    ptr = read_provider()
    return ptr if ptr and provider_command(ptr) else None


def active_name(check_api: bool = False) -> str | None:
    """Which saved profile the live login belongs to.

    Claude Code rotates the access token every few hours, so a value match only
    works right after a switch. The pointer file says which account we put there.
    With check_api=True we confirm the pointer still describes the same account
    by asking the API for the live token's uuid - used before we overwrite a
    saved profile with the live block. If the API is unreachable we trust the
    pointer.
    """
    live = live_oauth()
    if not live:
        return None
    tok = live.get("accessToken")
    for n in list_profiles():
        if (peek_profile(n).get(OAUTH_KEY) or {}).get("accessToken") == tok:
            return n
    ptr = read_ptr()
    if not ptr or ptr not in list_profiles():
        return None
    if check_api:
        saved_uuid = load_profile(ptr).get("accountUuid")
        live_uuid = identity(live).get("accountUuid")
        if saved_uuid and live_uuid and saved_uuid != live_uuid:
            return None  # someone logged in as a different account behind our back
    return ptr


# ------------------------------------------------------------------------ API


_IDENT_CACHE: dict[str, dict] = {}


def api_profile(token: str, timeout: float = API_TIMEOUT) -> tuple[int, dict]:
    import urllib.error
    import urllib.request

    req = urllib.request.Request(
        PROFILE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": f"{PROG}/{VERSION}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}


def identity(block: dict) -> dict:
    """email / uuid / plan for a credential block, via the API. {} if unreachable."""
    tok = block.get("accessToken")
    if not tok:
        return {}
    if OFFLINE:
        return {"tokenState": "not checked"}
    if tok not in _IDENT_CACHE:
        _IDENT_CACHE[tok] = _identity_uncached(tok)
    return _IDENT_CACHE[tok]


def _identity_uncached(tok: str) -> dict:
    status, body = api_profile(tok)
    if status == 200:
        a = body.get("account", {})
        org = body.get("organization", {})
        # Team/enterprise seats have neither the max nor the pro flag set; the
        # plan only shows up as the organization type.
        if a.get("has_claude_max"):
            plan = "max"
        elif a.get("has_claude_pro"):
            plan = "pro"
        else:
            plan = (org.get("organization_type") or "-").replace("claude_", "")
        return {
            "email": a.get("email"),
            "accountUuid": a.get("uuid"),
            "plan": plan,
            "org": org.get("name"),
            "tokenState": "ok",
        }
    if status == 403:
        return {"tokenState": "limited-scope"}
    if status in (401, 400):
        return {"tokenState": "invalid"}
    return {"tokenState": f"http {status}" if status else "offline"}


def identify_many(blocks: dict[str, dict]) -> dict[str, dict]:
    """identity() for several accounts at once - one API round trip of latency."""
    todo = {n: b for n, b in blocks.items() if b.get("accessToken")}
    if len(todo) < 2 or OFFLINE:
        return {n: identity(b) for n, b in blocks.items()}
    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=min(8, len(todo))) as pool:
        list(pool.map(lambda b: identity(b), todo.values()))
    return {n: identity(b) for n, b in blocks.items()}


VERIFY_CACHE = os.path.join(ACCOUNTS, ".verify-cache")
VERIFY_FRESH_S = 60  # a verification this young is shown again without asking


def read_verify_cache() -> dict:
    try:
        with open(VERIFY_CACHE) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def verify_row(entry: dict | None, now: float, no_cache: bool = False) -> dict | None:
    """The cached identity entry if fresh and usable, else None.

    The cache holds email, plan, accountUuid, tokenState and fetchedAt - no tokens.
    """
    if no_cache or not entry or not isinstance(entry, dict):
        return None
    if not entry.get("tokenState"):
        return None
    fetched = entry.get("fetchedAt") or 0
    if now - fetched < VERIFY_FRESH_S:
        return entry
    return None


def refresh_block(block: dict, timeout: float = API_TIMEOUT) -> tuple[dict | None, dict, str]:
    """Trade a refresh token for a fresh credential block. (block, identity, error).

    The refresh token is single use. A successful call rotates it and the old
    one stops working the moment the response is written, so whatever comes back
    MUST be persisted or the account is locked out - which is exactly how a
    hand-run refresh can destroy a login that had days left on it.
    """
    import urllib.error
    import urllib.request

    rt = block.get("refreshToken")
    if not rt:
        return None, {}, "no refresh token saved"
    body = json.dumps(
        {"grant_type": "refresh_token", "refresh_token": rt, "client_id": CLIENT_ID}
    ).encode()
    req = urllib.request.Request(
        TOKEN_URL,
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": f"{PROG}/{VERSION}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read().decode()).get("error_description") or ""
        except Exception:
            detail = ""
        if e.code in (400, 401):
            return None, {}, detail or "the refresh token was rejected; log in again"
        return None, {}, f"http {e.code}{': ' + detail if detail else ''}"
    except Exception as e:
        return None, {}, str(e)

    if not payload.get("access_token") or not payload.get("refresh_token"):
        return None, {}, "the token endpoint returned no credential"
    now = time.time()
    fresh = dict(block)
    fresh["accessToken"] = payload["access_token"]
    fresh["refreshToken"] = payload["refresh_token"]
    fresh["expiresAt"] = int((now + payload.get("expires_in", 0)) * 1000)
    if payload.get("refresh_token_expires_in"):
        fresh["refreshTokenExpiresAt"] = int(
            (now + payload["refresh_token_expires_in"]) * 1000
        )
    if payload.get("scope"):
        fresh["scopes"] = payload["scope"].split()
    acct = payload.get("account") or {}
    ident = {
        "email": acct.get("email_address"),
        "accountUuid": acct.get("uuid"),
        "org": (payload.get("organization") or {}).get("name"),
    }
    return fresh, {k: v for k, v in ident.items() if v}, ""


def expired(block: dict) -> bool:
    exp = block.get("expiresAt")
    return bool(exp) and exp / 1000 <= time.time()


def humanise(seconds: float) -> str:
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 86400)}d"


def expiry_note(block: dict) -> str:
    exp = block.get("expiresAt")
    if not exp:
        return "-"
    left = exp / 1000 - time.time()
    if left <= 0:
        return f"{DIM}expired (auto-renews){OFF}"
    return f"{humanise(left)} left"


def refresh_left(block: dict) -> float | None:
    """Seconds until the refresh token dies, i.e. until a real re-login."""
    exp = block.get("refreshTokenExpiresAt")
    if not exp:
        return None
    return exp / 1000 - time.time()


def token_state(block: dict, ident: dict) -> str:
    """What --verify should print for one account.

    An access token that has simply aged out reads as `invalid` to the API, but
    Claude Code renews it from the refresh token on the next start - that is not
    a broken account, so say so differently.
    """
    state = ident.get("tokenState", "?")
    if state != "invalid":
        return state
    exp = block.get("expiresAt")
    rleft = refresh_left(block)
    if exp and exp / 1000 <= time.time() and (rleft is None or rleft > 0):
        return "stale (renews)"
    return "invalid"



# A login is good for up to about 30 days and nothing a client does moves that
# date. Measured again 2026-08-31 by refreshing a saved token by hand: the call
# rotates the refresh token, and the new one came back with
# refresh_token_expires_in = 395028s, landing on the same wall-clock minute the
# old one was already going to die. Access tokens are a flat 8h. So renewing
# keeps a profile usable day to day and buys the account nothing; only a real
# login resets the clock, and it can hand back less than 30 days - one account
# re-logged-in that morning got 27.5. Two weeks of notice is enough to plan one
# sitting; one week is not.
RELOGIN_NOTICE = 14 * 86400


def refresh_warning(block: dict) -> str | None:
    left = refresh_left(block)
    if left is None:
        return None
    if left <= 0:
        return f"refresh token expired - this account needs `{PROG} add` again"
    if left < RELOGIN_NOTICE:
        return f"refresh token expires in {humanise(left)}"
    return None


def effective_blocks(
    profiles: dict[str, dict], cur: str | None, live: dict | None
) -> dict[str, dict]:
    """The credential that actually applies to each account right now.

    A saved profile is a snapshot from the last hop or sync. For whichever
    account is live the credential store is newer by definition - Claude Code
    rotates the token every few hours and a browser re-login replaces it
    outright - so judging the active account by its snapshot is how this tool
    ends up calling a perfectly good login expired.
    """
    blocks = {n: p.get(OAUTH_KEY, {}) or {} for n, p in profiles.items()}
    for n in blocks:  # a `run` session rotates its own copy, which is then the newest
        newest = run_block(n)
        if newest and _issued_later(newest, blocks[n]):
            blocks[n] = newest
    if cur and live and cur in blocks:
        blocks[cur] = live
    return blocks


def relogin_plan(blocks: dict[str, dict]) -> dict | None:
    """When each account needs a real /login again, and the cheapest day to do it.

    Logging in early resets the whole 30-day window, so doing every account on the
    day the earliest one comes due collapses them onto a single date - one sitting
    a month instead of one surprise per account.
    """
    due = {
        n: b["refreshTokenExpiresAt"] / 1000
        for n, b in blocks.items()
        if b.get("refreshTokenExpiresAt")
    }
    if not due:
        return None
    now = time.time()
    live = {n: t for n, t in due.items() if t > now}
    plan = {
        "accounts": len(due),
        "expired": sorted(n for n, t in due.items() if t <= now),
        "first": None,
        "firstAccounts": [],
        "last": None,
        "spreadDays": 0.0,
    }
    if live:
        first, last = min(live.values()), max(live.values())
        plan["first"] = first
        # Anything inside a day of the earliest is part of the same sitting.
        plan["firstAccounts"] = sorted(n for n, t in live.items() if t - first < 86400)
        plan["last"] = last
        plan["spreadDays"] = (last - first) / 86400
    return plan


def relogin_lines(plan: dict) -> list[str]:
    """The `re-login` block for doctor. Empty when there is nothing to say."""
    day = lambda ts: time.strftime("%Y-%m-%d", time.localtime(ts))  # noqa: E731
    lines: list[str] = []
    if plan["expired"]:
        lines.append(
            f"expired: {', '.join(plan['expired'])} - `{PROG} add <name>` to sign in again"
        )
    if not plan["first"]:
        return lines
    head = f"by {day(plan['first'])} ({', '.join(plan['firstAccounts'])})"
    others = plan["accounts"] - len(plan["firstAccounts"]) - len(plan["expired"])
    if others <= 0 or plan["spreadDays"] < 1:
        lines.append(head)
        return lines
    rest = "the other one" if others == 1 else f"the other {others}"
    lines.append(f"{head}; {rest} by {day(plan['last'])}")
    lines += textwrap.wrap(
        f"windows are ~30d from login and do not slide, so re-login all "
        f"{plan['accounts']} on {day(plan['first'])} and they collapse to one date",
        width=68,
    )
    return lines


# --------------------------------------------------------------------- checks


def running_claude_pids() -> list[int]:
    """PIDs of other `claude` processes. Best effort, never raises."""
    me = os.getpid()
    pids: list[int] = []
    if os.path.isdir("/proc"):
        try:
            entries = os.listdir("/proc")
        except OSError:
            entries = []
        for entry in entries:
            if not entry.isdigit() or int(entry) == me:
                continue
            try:
                with open(f"/proc/{entry}/cmdline", "rb") as f:
                    argv0 = f.read().split(b"\0")[0].decode(errors="replace")
            except OSError:
                continue
            if os.path.basename(argv0) in ("claude", "claude.exe"):
                pids.append(int(entry))
        return sorted(pids)
    # macOS and anything else without /proc.
    if not shutil.which("pgrep"):
        return []
    try:
        out = subprocess.run(
            ["pgrep", "-x", "claude"], capture_output=True, text=True, timeout=5
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    for line in out.split():
        if line.isdigit() and int(line) != me:
            pids.append(int(line))
    return sorted(pids)


def warn_running():
    pids = running_claude_pids()
    if pids:
        info(
            f"{YELLOW}note:{OFF} {len(pids)} claude session(s) open "
            f"(pid {', '.join(map(str, pids))}). Each one follows this on its next message, so a "
            f"conversation under way moves to the new account's usage and starts a new prompt cache."
        )


class _TerminalGone(Exception):
    """SIGHUP/SIGTERM arrived - unwind so the cleanup blocks get to run."""


def _guard_child_signals() -> dict:
    """Make a long interactive child safe to wait on. Returns what to restore.

    Two different problems, both of which lost a finished login:

    * SIGINT. Claude Code uses Ctrl-C to cancel the current turn, not to quit,
      so the first one must not unwind this process - it would save and exit
      while `claude` is still running and still writing to the credential store.
      A shell ignores SIGINT while a foreground child runs; do the same. This
      has to be a no-op Python handler rather than SIG_IGN, because SIG_IGN
      survives exec and would leave `claude` itself unable to see Ctrl-C.
    * SIGHUP/SIGTERM. The default action kills us outright, which skips every
      cleanup path and drops a credential that has already been issued. Turn
      them into an exception instead.
    """

    def ignore(signum, frame):
        pass

    def bail(signum, frame):
        raise _TerminalGone(signum)

    old: dict = {}
    for sig, handler in (
        (getattr(signal, "SIGINT", None), ignore),
        (getattr(signal, "SIGHUP", None), bail),
        (getattr(signal, "SIGTERM", None), bail),
    ):
        if sig is None:
            continue
        try:
            old[sig] = signal.signal(sig, handler)
        except (OSError, ValueError):  # not the main thread, or unsupported here
            pass
    return old


def _restore_signals(old: dict):
    for sig, handler in old.items():
        try:
            signal.signal(sig, handler)
        except (OSError, ValueError):
            pass


def confirm(question: str, assume_yes: bool) -> bool:
    if assume_yes or not sys.stdin.isatty():
        return True
    try:
        return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def slug(email: str) -> str:
    s = re.sub(r"[^a-z0-9._-]", "-", email.split("@")[0].lower()).strip("-.") or "account"
    if not VALID_NAME.match(s):
        s = "account-" + s.lstrip("-.")
    # An account called `list` would shadow the command of the same name.
    return f"{s}-acct" if s in COMMANDS else s


def stash_live(live: dict) -> str:
    """Save an unrecognised live login under its own name. Returns that name."""
    ident = identity(live)
    name = slug(ident["email"]) if ident.get("email") else f"unsaved-{int(time.time())}"
    save_profile(name, live, {k: v for k, v in ident.items() if k != "tokenState"})
    return name


def sync_live_before_switch(live: dict) -> str | None:
    """Never drop a login we cannot get back. Returns the profile it went to."""
    cur = active_name(check_api=True)
    if cur:
        save_profile(cur, live, {})
        return cur
    name = stash_live(live)
    info(f"{DIM}stashed the current login as '{name}' first{OFF}")
    return name


# ---------------------------------------------------------------------- usage
#
# How much of each account's 5-hour and 7-day allowance is spent, from the same
# endpoint Claude Code's own /usage reads. It budgets requests from clients
# that are not Claude Code, and a throttled token is blocked for a long time
# (a Retry-After of about 25 minutes was seen), so this runs only when asked,
# keeps the last good reading on disk, and never asks again before the server's
# Retry-After has passed. The cache holds percentages and times, no tokens.

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USAGE_CACHE = os.path.join(ACCOUNTS, ".usage-cache")
USAGE_FRESH_S = 60  # a reading this young is shown again without asking
USAGE_THROTTLE_DEFAULT_S = 600  # when a 429 names no Retry-After
USAGE_THROTTLE_MAX_S = 3600


def api_usage(token: str, timeout: float = API_TIMEOUT) -> tuple[int, dict, float | None]:
    """(status, body, Retry-After in seconds if the server sent one)."""
    import urllib.error
    import urllib.request

    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": f"{PROG}/{VERSION}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode()), None
    except urllib.error.HTTPError as e:
        try:
            retry = float(e.headers.get("Retry-After") or "")
        except ValueError:
            retry = None
        try:
            body = json.loads(e.read().decode())
        except Exception:
            body = {}
        return e.code, body, retry
    except Exception as e:
        return 0, {"error": str(e)}, None


def parse_usage(body: dict) -> dict:
    """The windows in a usage reply: {"five_hour": {"pct": 42.0, "resetsAt": "..."}, ...}.

    Anything that is not a window with a numeric `utilization` (a null window,
    a field we do not know) is skipped, so a new field never breaks the table.
    """
    out = {}
    for key, win in (body or {}).items():
        if not isinstance(win, dict):
            continue
        pct = win.get("utilization")
        if isinstance(pct, (int, float)) and not isinstance(pct, bool):
            out[key] = {"pct": float(pct), "resetsAt": win.get("resets_at")}
    return out


def seconds_until(iso: str | None) -> float | None:
    if not iso or not isinstance(iso, str):
        return None
    from datetime import datetime

    # Python 3.9's fromisoformat takes only 3 or 6 fractional digits and no `Z`.
    iso = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], iso.replace("Z", "+00:00"))
    try:
        when = datetime.fromisoformat(iso)
    except ValueError:
        return None
    if when.tzinfo is None:
        return None
    return when.timestamp() - time.time()


def countdown(seconds: float) -> str:
    seconds = max(0, int(seconds))
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return f"{days}d{hours}h"
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def read_usage_cache() -> dict:
    try:
        with open(USAGE_CACHE) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def usage_row(entry: dict, block: dict, now: float, renew_hint: str = "", no_cache: bool = False) -> dict:
    """One account's reading: the cached entry, refreshed if it is allowed and due.

    Returns the entry to keep (windows, fetchedAt, throttledUntil) plus a `note`
    that says why a reading is old or missing.
    """
    entry = dict(entry or {})
    if OFFLINE:
        entry["note"] = "offline mode" if entry.get("windows") else "offline mode, nothing cached"
        return entry
    until = entry.get("throttledUntil") or 0
    if until > now:
        entry["note"] = f"throttled by the server, ask again in {countdown(until - now)}"
        return entry
    fetched = entry.get("fetchedAt") or 0
    if not no_cache and entry.get("windows") and now - fetched < USAGE_FRESH_S:
        return entry
    tok = block.get("accessToken")
    if not tok:
        entry["note"] = "no saved login"
    elif expired(block):
        entry["note"] = f"access token aged out; {renew_hint}" if renew_hint else "access token aged out"
    else:
        status, body, retry = api_usage(tok)
        if status == 200:
            entry["windows"] = parse_usage(body)
            entry["fetchedAt"] = now
            entry.pop("throttledUntil", None)
        elif status == 429:
            wait = min(retry if retry is not None else USAGE_THROTTLE_DEFAULT_S, USAGE_THROTTLE_MAX_S)
            entry["throttledUntil"] = now + wait
            entry["note"] = f"throttled by the server, ask again in {countdown(wait)}"
        elif status in (401, 403):
            entry["note"] = "the server rejected this token"
        else:
            entry["note"] = f"http {status}" if status else "could not reach the server"
    return entry


def cmd_usage(name=None, as_json=False, no_cache=False, **_):
    """Where each account stands against its 5-hour and 7-day limits."""
    names = list_profiles()
    if name:
        load_profile(name)  # dies with the usual message if there is no such account
        names = [name]
    if not names:
        die(f"no saved accounts. Add one with `{PROG} add <name>`.")
    profiles = {n: load_profile(n) for n in names}
    cur = active_name()
    blocks = effective_blocks(profiles, cur, live_oauth())
    cache = read_usage_cache()
    now = time.time()

    def renew_hint(n: str) -> str:
        if n == cur:
            return "Claude Code renews it on its next call"
        return f"`{PROG} renew {n}` refreshes it"

    rows = {n: usage_row(cache.get(n), blocks[n], now, renew_hint(n), no_cache=no_cache) for n in names}
    for n, row in rows.items():
        cache[n] = {k: v for k, v in row.items() if k != "note"}
    cache = {n: v for n, v in cache.items() if n in list_profiles()}
    try:
        profiles_dir()
        write_json_secure(USAGE_CACHE, cache)
    except OSError:
        pass  # a cache we cannot write only costs the next run a request

    if as_json:
        print(
            json.dumps(
                {
                    "accounts": [
                        {
                            "name": n,
                            "active": n == cur,
                            "windows": rows[n].get("windows") or {},
                            "fetchedAt": rows[n].get("fetchedAt"),
                            "throttledUntil": rows[n].get("throttledUntil"),
                            "note": rows[n].get("note"),
                        }
                        for n in names
                    ]
                },
                indent=2,
            )
        )
        return

    def cell(row: dict, key: str) -> str:
        win = (row.get("windows") or {}).get(key)
        if not win:
            return "-"
        left = seconds_until(win.get("resetsAt"))
        return f"{win['pct']:.0f}%" + (f"  resets {countdown(left)}" if left and left > 0 else "")

    table, lit = [], set()
    for i, n in enumerate(names):
        row = rows[n]
        note = row.get("note") or ""
        age = now - row["fetchedAt"] if row.get("windows") and row.get("fetchedAt") else 0
        if age > USAGE_FRESH_S:
            note = f"{note}; " if note else ""
            note += f"last reading {countdown(age)} ago"
        table.append(("*" if n == cur else " ", n, cell(row, "five_hour"), cell(row, "seven_day"), note))
        if n == cur:
            lit.add(i)
    print_table(("", "NAME", "5 HOURS", "7 DAYS", "NOTE"), table, lit)


# ------------------------------------------------------------------ run sessions
#
# `hop run <name>` starts one `claude` on its own account without touching the
# live login, so two terminals can be on two accounts at once. Claude Code reads
# its login again before each message, so a global hop cannot do that.
#
# Each account gets a config home of its own, <accounts>/.run/<name>/, and
# `claude` is pointed at it with CLAUDE_CONFIG_DIR. That home holds the account's
# login and a copy of the global config; everything that defines how Claude
# behaves for you (settings, CLAUDE.md, skills, agents, plugins, projects, prompt
# history) is a symlink to the real one, so a run session looks like your normal
# one. The login in that home is the one Claude Code rotates, so it is the newest
# copy while a session lives; it is saved back to the profile when the session
# ends, and reconciled by expiry the next time (and by `doctor` after a crash).
#
# Never two copies of one login: the live account is not given a second home
# (it just runs `claude`), and while a session is open `use` and `renew` leave
# its account alone, because rotating a refresh token under it would sign one of
# the two out.

RUN_DIR = os.path.join(ACCOUNTS, ".run")

# Linked into every run home. Credentials and identity are deliberately absent,
# as are caches and per-session state. CLAUDE_HOP_SHARE adds names to the list.
SHARED_ENTRIES = (
    "CLAUDE.md", "settings.json", "settings.local.json", "keybindings.json",
    "agents", "commands", "hooks", "output-styles", "skills", "plugins",
    "projects", "plans", "todos", "file-history", "history.jsonl",
)
NEVER_SHARED = {".credentials.json", ".credentials.json.bak", ".claude.json", "accounts"}


def run_home(name: str) -> str:
    return os.path.join(RUN_DIR, name)


def run_creds_path(name: str) -> str:
    return os.path.join(run_home(name), ".credentials.json")


def global_config_path() -> str:
    """Where Claude Code keeps its global config: inside the config dir if
    CLAUDE_CONFIG_DIR is set, otherwise ~/.claude.json beside it."""
    if env("CLAUDE_CONFIG_DIR"):
        return os.path.join(CLAUDE_DIR, ".claude.json")
    return os.path.join(HOME, ".claude.json")


def _proc_start(pid: int) -> str:
    """The start time /proc records for a pid; it tells a reused pid from ours."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return ""


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True  # exists, just not ours to signal
    return True


def run_pids(name: str) -> list[int]:
    """Open `hop run` sessions for this account. Entries for dead ones are dropped."""
    d = os.path.join(run_home(name), ".hop-pids")
    try:
        entries = os.listdir(d)
    except OSError:
        return []
    alive = []
    for e in entries:
        if not e.isdigit():
            continue
        pid = int(e)
        try:
            with open(os.path.join(d, e)) as f:
                started = f.read().strip()
        except OSError:
            continue
        if (_proc_start(pid) == started) if started else _pid_alive(pid):
            alive.append(pid)
        else:
            try:
                os.remove(os.path.join(d, e))
            except OSError:
                pass
    return sorted(alive)


def _register_pid(name: str, pid: int):
    d = os.path.join(run_home(name), ".hop-pids")
    os.makedirs(d, mode=0o700, exist_ok=True)
    with open(os.path.join(d, str(pid)), "w") as f:
        f.write(_proc_start(pid))


def _unregister_pid(name: str, pid: int):
    try:
        os.remove(os.path.join(run_home(name), ".hop-pids", str(pid)))
    except OSError:
        pass


def run_block(name: str) -> dict | None:
    """The login in an account's run home, if there is one."""
    try:
        with open(run_creds_path(name)) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    block = doc.get(OAUTH_KEY) if isinstance(doc, dict) else None
    return block if isinstance(block, dict) and block.get("accessToken") else None


def _issued_later(a: dict | None, b: dict | None) -> bool:
    """True if login block a was issued after b. Access tokens last a flat 8 hours
    from issue, so a later expiry means a later token."""
    return ((a or {}).get("expiresAt") or 0) > ((b or {}).get("expiresAt") or 0)


def _write_run_creds(name: str, block: dict):
    path = run_creds_path(name)
    try:
        with open(path) as f:
            doc = json.load(f)
        if not isinstance(doc, dict):
            doc = {}
    except (OSError, ValueError):
        doc = {}
    doc[OAUTH_KEY] = block  # anything else in there (MCP logins) stays
    write_json_secure(path, doc)


def _link_shared(home: str):
    names = list(SHARED_ENTRIES)
    for extra in (env("CLAUDE_HOP_SHARE") or "").split(","):
        extra = extra.strip()
        if extra and os.sep not in extra and extra not in (".", "..") and extra not in NEVER_SHARED:
            names.append(extra)
    for entry in names:
        src, dst = os.path.join(CLAUDE_DIR, entry), os.path.join(home, entry)
        if os.path.islink(dst):
            if os.readlink(dst) == src:
                continue
            os.remove(dst)
        elif os.path.lexists(dst):
            continue  # a real file or folder in the run home; not ours to replace
        if os.path.lexists(src):
            os.symlink(src, dst)


def _copy_global_config(home: str):
    """The global config, minus which account it was last signed in as.

    Claude Code looks that up again at startup. Copied rather than linked: two
    sessions on two accounts would keep overwriting each other's `oauthAccount`.
    Changes made inside a run session (a new MCP server, a trust prompt) stay in
    its home.
    """
    try:
        with open(global_config_path()) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return
    if isinstance(doc, dict):
        doc.pop("oauthAccount", None)
        write_json_secure(os.path.join(home, ".claude.json"), doc)


def prepare_run_home(name: str, profile_block: dict) -> str:
    """Make <accounts>/.run/<name>/ ready for a session. Call with lock() held."""
    home = run_home(name)
    os.makedirs(home, mode=0o700, exist_ok=True)
    os.chmod(RUN_DIR, 0o700)
    if os.stat(home).st_mode & 0o077:
        os.chmod(home, 0o700)
    if not run_pids(name):  # with a session open its login is the live one: hands off
        have = run_block(name)
        if not have:
            _write_run_creds(name, profile_block)
        elif have.get("accessToken") != profile_block.get("accessToken"):
            if _issued_later(profile_block, have):  # logged in again since: that wins
                _write_run_creds(name, profile_block)
            else:  # the session rotated it: bring the profile up to date
                save_profile(name, have, {})
        _copy_global_config(home)
    _link_shared(home)
    return home


def capture_run_login(name: str) -> bool:
    """Save the login in the run home back to the profile. True if that changed it.

    A `/login` inside the session could have signed in as somebody else. A
    rotation keeps the same 30-day window, a new login starts a fresh one, so a
    window that jumped is checked against the API before it is filed under this
    name.
    """
    new = run_block(name)
    if not new:
        return False
    prof = peek_profile(name)
    old = prof.get(OAUTH_KEY) or {}
    if new.get("accessToken") == old.get("accessToken"):
        return False
    window_new = new.get("refreshTokenExpiresAt") or 0
    window_old = old.get("refreshTokenExpiresAt") or 0
    if window_new > window_old + 3600_000 and not OFFLINE:
        ident = identity(new)
        was, now_ = prof.get("accountUuid"), ident.get("accountUuid")
        if was and now_ and was != now_:
            other = stash_live(new)
            if old:
                _write_run_creds(name, old)  # the home goes back to being this account's
            info(
                f"{YELLOW}note:{OFF} you signed in as {ident.get('email') or 'another account'} inside "
                f"the '{name}' session. Saved that login as '{other}'; '{name}' is unchanged."
            )
            return True
    save_profile(name, new, {})
    return True


def remove_run_home(name: str):
    """Delete a run home. Symlinks are unlinked, never followed: they point at
    your real settings and projects."""
    home = run_home(name)
    if not os.path.isdir(home):
        return
    for root, dirs, files in os.walk(home, topdown=False, followlinks=False):
        for f in files:
            os.remove(os.path.join(root, f))
        for d in dirs:
            p = os.path.join(root, d)
            if os.path.islink(p):
                os.remove(p)
            else:
                os.rmdir(p)
    os.rmdir(home)


def cmd_run(name=None, rest=None, **_):
    """Run `claude` as one account in this terminal only."""
    rest = list(rest or [])
    if not name or name.startswith("-"):
        die(f"usage: {PROG} run <name> [claude arguments]", USAGE_EXIT)
    if STORE.name != "file":
        die(
            f"`{PROG} run` needs the credential file. This machine keeps Claude Code's login in the "
            f"{STORE.name}, and a second login under another config dir is not handled there yet."
        )
    claude = shutil.which("claude")
    if not claude:
        die("`claude` is not on your PATH.")
    for var in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"):
        if os.environ.get(var):
            info(f"{YELLOW}warning:{OFF} ${var} is set in this shell and overrides the saved login.")

    with lock():
        target = load_profile(name)
        blk = target.get(OAUTH_KEY)
        if not blk:
            die(f"'{name}' has no saved credentials. Re-save it with `{PROG} add {name}`.")
        if active_name() == name and live_oauth():
            info(f"{DIM}'{name}' is the live login, so this is plain `claude`. "
                 f"A later hop moves it, as it does every open session.{OFF}")
            os.execv(claude, [claude, *rest])
        home = prepare_run_home(name, blk)
        warn = refresh_warning(run_block(name) or blk)
        if warn:
            info(f"{YELLOW}note:{OFF} {warn}")
        info(f"{DIM}claude as {name} ({target.get('email') or 'email unknown'}), config home {home}{OFF}")
        old_signals = _guard_child_signals()
        try:
            proc = subprocess.Popen([claude, *rest], env={**os.environ, "CLAUDE_CONFIG_DIR": home})
        except OSError as e:
            _restore_signals(old_signals)
            die(f"could not start claude: {e}")
        _register_pid(name, proc.pid)

    code = 1
    try:
        try:
            code = proc.wait()
        except _TerminalGone:
            try:
                code = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                code = 1
    finally:
        try:
            _unregister_pid(name, proc.pid)
            with lock():
                if capture_run_login(name):
                    info(f"{DIM}saved the renewed login for {name}{OFF}")
        finally:
            _restore_signals(old_signals)
    sys.exit(128 - code if code < 0 else code)


# ------------------------------------------------------------------- commands


def print_table(hdr: tuple, rows: list, highlight=()):
    """Columns wide enough for their widest cell; highlight those row indexes."""
    w = [max(visible_len(str(r[i])) for r in [hdr, *rows]) for i in range(len(hdr))]
    print(DIM + "  ".join(pad(str(h), w[i]) for i, h in enumerate(hdr)).rstrip() + OFF)
    for i, r in enumerate(rows):
        line = "  ".join(pad(str(c), w[j]) for j, c in enumerate(r)).rstrip()
        print((GREEN + line + OFF) if i in highlight else line)


def cmd_list(verify=False, as_json=False, long_=False, no_cache=False, **_):
    names = list_profiles()
    provs = list_providers()
    prov = active_provider()
    live = live_oauth()
    cur = active_name(check_api=verify)
    if not names and not provs and not as_json:
        info("No accounts saved yet.")
        if live:
            info(f"You are logged in - save this one with:  {PROG} save <name>")
        else:
            info(f"Log in with:  {PROG} add <name>")
        return

    profiles = {n: load_profile(n) for n in names}
    blocks = effective_blocks(profiles, cur, live)
    idents: dict[str, dict] = {}
    if verify:
        cache = {} if no_cache else read_verify_cache()
        now = time.time()
        to_fetch: dict[str, dict] = {}
        for n in names:
            blk = blocks[n]
            hit = verify_row(cache.get(n), now, no_cache=no_cache)
            if hit is not None:
                idents[n] = hit
            else:
                to_fetch[n] = blk
        if to_fetch:
            fresh = identify_many(to_fetch)
            for n, ident in fresh.items():
                idents[n] = ident
                if not OFFLINE and ident.get("tokenState"):
                    cache[n] = {
                        "email": ident.get("email"),
                        "plan": ident.get("plan"),
                        "accountUuid": ident.get("accountUuid"),
                        "tokenState": ident.get("tokenState"),
                        "fetchedAt": now,
                    }
            if not OFFLINE:
                cache = {n: v for n, v in cache.items() if n in list_profiles()}
                try:
                    profiles_dir()
                    write_json_secure(VERIFY_CACHE, cache)
                except OSError:
                    pass

        for n, ident in idents.items():
            if not ident.get("email"):
                continue
            p = profiles[n]
            fresh_meta = {k: ident[k] for k in ("email", "plan", "accountUuid") if ident.get(k)}
            if any(p.get(k) != v for k, v in fresh_meta.items()):
                p.update(fresh_meta)
                write_json_secure(profile_path(n), p)

    if as_json:
        print(
            json.dumps(
                {
                    "backend": STORE.name,
                    "active": cur,
                    "provider": prov,
                    "providers": [
                        {"name": p, "command": provider_command(p), "active": p == prov}
                        for p in provs
                    ],
                    "accounts": [
                        {
                            "name": n,
                            "email": profiles[n].get("email"),
                            "plan": profiles[n].get("plan"),
                            "accountUuid": profiles[n].get("accountUuid"),
                            "savedAt": profiles[n].get("savedAt"),
                            "active": n == cur,
                            "expiresAt": blocks[n].get("expiresAt"),
                            "refreshTokenExpiresAt": blocks[n].get("refreshTokenExpiresAt"),
                            "tokenState": token_state(blocks[n], idents[n])
                            if verify
                            else None,
                        }
                        for n in names
                    ],
                },
                indent=2,
            )
        )
        return

    # Default columns answer the only question that matters - which account is
    # which. Token expiry and save dates needed a paragraph of explanation to be
    # readable at all, so they moved behind --long. STATE only means something
    # once we have actually asked the API.
    hdr = ("", "NAME", "EMAIL", "PLAN")
    if verify:
        hdr += ("STATE",)
    if long_:
        hdr += ("TOKEN", "SAVED")
    rows = []
    for n in names:
        blk = blocks[n]
        row = (
            "*" if n == cur and not prov else " ",
            n,
            profiles[n].get("email") or "?",
            profiles[n].get("plan") or "?",
        )
        if verify:
            row += (token_state(blk, idents.get(n, {})),)
        if long_:
            row += (expiry_note(blk), (profiles[n].get("savedAt") or "")[:10])
        rows.append(row)
    for p in provs:
        cmd = provider_command(p) or "?"
        row = ("*" if p == prov else " ", p, f"runs {cmd}", "provider")
        if verify:
            row += ("ok" if shutil.which(cmd) else "command not found",)
        if long_:
            row += ("", "")
        rows.append(row)
    lit = {i for i, n in enumerate(names) if n == cur and not prov}
    lit |= {len(names) + i for i, p in enumerate(provs) if p == prov}
    print_table(hdr, rows, lit)

    for n in names:
        warn = refresh_warning(blocks[n])
        if warn:
            info(f"{YELLOW}note:{OFF} {n}: {warn}")
    if cur is None and live:
        info(
            f"\n{YELLOW}note:{OFF} the current login does not match any saved account. "
            f"Save it with:  {PROG} save <name>"
        )


def cmd_pick(yes=False, no_sync=False, verify=False, as_json=False, long_=False, no_cache=False, **_):
    """`hop` with nothing after it: show the accounts and offer to switch.

    The tool exists to answer one question - which account? - so ask it, instead
    of printing a table and making you retype a name out of it. Falls back to a
    plain listing when there is nothing to choose between, or when stdout is a
    pipe and there is nobody there to answer.
    """
    names = list_profiles()
    provs = list_providers()
    choices = names + provs
    if len(choices) < 2 or not (sys.stdin.isatty() and sys.stdout.isatty()):
        cmd_list(verify=verify, as_json=as_json, long_=long_, no_cache=no_cache)
        return

    profiles = {n: load_profile(n) for n in names}
    cur = active_name()
    prov = active_provider()
    rows = [
        (f"{i}. *" if n == cur and not prov else f"{i}.", n,
         profiles[n].get("email") or "?", profiles[n].get("plan") or "?")
        for i, n in enumerate(names, 1)
    ]
    rows += [
        (f"{len(names) + j}. *" if p == prov else f"{len(names) + j}.", p,
         f"runs {provider_command(p) or '?'}", "provider")
        for j, p in enumerate(provs, 1)
    ]
    lit = {i for i, n in enumerate(names) if n == cur and not prov}
    lit |= {len(names) + j for j, p in enumerate(provs) if p == prov}
    print_table(("", "NAME", "EMAIL", "PLAN"), rows, lit)
    try:
        answer = input(f"\nhop to which? [1-{len(choices)}, Enter to stay] ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return
    if not answer:
        return

    if answer.isdigit() and 1 <= int(answer) <= len(choices):
        chosen = choices[int(answer) - 1]
    else:  # a name, or enough of one to be unambiguous
        hits = [n for n in choices if n == answer] or [n for n in choices if n.startswith(answer)]
        if len(hits) != 1:
            die(f"'{answer}' is not one of them. Pick a number, or a name.", USAGE_EXIT)
        chosen = hits[0]

    if chosen in provs:
        if chosen == prov:
            print(f"already on {GREEN}{chosen}{OFF}")
        else:
            cmd_provider_on(chosen)
        return
    if chosen == cur and not prov:
        print(f"already on {GREEN}{chosen}{OFF}")
        return
    cmd_use(name=chosen, yes=yes, no_sync=no_sync)


def cmd_active(as_json=False, **_):
    cur = active_name()
    prov = active_provider()
    if as_json:
        print(json.dumps({"active": cur, "provider": prov, "backend": STORE.name}))
    elif prov:
        print(prov)  # what a new `claude` will run as; --json keeps the account too
    elif cur:
        print(cur)
    else:
        sys.exit(1)


def cmd_whoami(as_json=False, **_):
    live = live_oauth()
    if not live:
        if as_json:
            print(json.dumps({"loggedIn": False, "backend": STORE.name}))
        else:
            print("not logged in")
        sys.exit(1)
    ident = identity(live)
    name = active_name(check_api=True)
    overrides = [
        v for v in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN") if os.environ.get(v)
    ]
    if as_json:
        print(
            json.dumps(
                {
                    "loggedIn": True,
                    "backend": STORE.name,
                    "account": name,
                    "email": ident.get("email"),
                    "plan": ident.get("plan") or live.get("subscriptionType"),
                    "org": ident.get("org"),
                    "accountUuid": ident.get("accountUuid"),
                    "tokenState": ident.get("tokenState"),
                    "expiresAt": live.get("expiresAt"),
                    "envOverrides": overrides,
                },
                indent=2,
            )
        )
        return
    email = ident.get("email") or "(could not reach the API)"
    plan = ident.get("plan") or live.get("subscriptionType") or "?"
    print(
        f"{BOLD}{email}{OFF}  [{plan}]  saved as: {name or '(unsaved)'}  "
        f"token: {expiry_note(live)}"
    )
    for var in overrides:
        info(f"{YELLOW}warning:{OFF} ${var} is set in this shell and overrides the saved login.")


def cmd_save(name=None, yes=False, **_):
    live = live_oauth()
    if not live:
        die("not logged in - nothing to save. Run `claude` and use /login first.")
    ident = identity(live)
    if not name:
        if not ident.get("email"):
            die("could not reach the API to name this account automatically - pass a name.")
        name = slug(ident["email"])
    check_new_name(name)
    if os.path.exists(profile_path(name)) and not confirm(f"overwrite saved account '{name}'?", yes):
        die("aborted")
    save_profile(name, live, {k: v for k, v in ident.items() if k != "tokenState"})
    set_active_ptr(name)
    print(f"saved {GREEN}{name}{OFF} ({ident.get('email') or 'email unknown'}) -> {profile_path(name)}")


def cmd_sync(**_):
    live = live_oauth()
    if not live:
        die("not logged in - nothing to sync.")
    n = active_name(check_api=True)
    if not n:
        die(f"current login is not one of the saved accounts. Use `{PROG} save <name>`.")
    save_profile(n, live, {})
    print(f"synced live login into {n}")


def cmd_renew(name=None, yes=False, **_):
    """Refresh saved logins in place. No name means all of them.

    This buys time on the access token, not on the account: the refresh window
    is a fixed date set when you logged in, and rotating the token does not move
    it. What it is for is keeping the saved copies usable and honest - a profile
    you have not hopped to in a fortnight still holds the token from that day,
    and renewing it here is how you find out it died before you need it.
    """
    if OFFLINE:
        die(f"{PROG} is in offline mode ($CLAUDE_HOP_OFFLINE); renewing needs the network.")
    names = list_profiles()
    if not names:
        die("no saved accounts to renew.")
    if name:
        load_profile(name)  # dies with the usual message if it is not a real one
        names = [name]

    cur = active_name()
    live = live_oauth()
    failed = 0
    for n in names:
        pids = run_pids(n)
        if pids and not yes:
            print(
                f"  {DIM}{n}{OFF}  skipped - open in a run session, "
                f"pid {', '.join(map(str, pids))} (--yes overrides)"
            )
            continue
        if not pids:
            capture_run_login(n)  # a session that has ended may hold the newer login
        blk = live if (n == cur and live) else load_profile(n).get(OAUTH_KEY, {})
        # Renewing rotates the refresh token, and the old one dies with the call.
        # A session that is already running holds the old one, so rotating the
        # live login out from under it is the one way this command can cost you
        # something. Inactive profiles have nobody holding them - do those.
        if n == cur and not yes:
            pids = running_claude_pids()
            if pids:
                print(
                    f"  {DIM}{n}{OFF}  skipped - the live login, with "
                    f"{len(pids)} session(s) running (--yes overrides)"
                )
                continue
        # Only the live login is in Claude Code's way: hold its refresh lock for
        # the whole round trip, as it does, and read the login again under it.
        with claude_lock() if n == cur and live else contextlib.nullcontext():
            if n == cur and live:
                blk = live_oauth() or blk
            left = refresh_left(blk)
            if not blk.get("refreshToken"):
                print(f"  {RED}{n}{OFF}  no saved credential - `{PROG} add {n}`")
                failed += 1
                continue
            if left is not None and left <= 0:
                print(f"  {RED}{n}{OFF}  refresh window closed - `{PROG} add {n}` to log in again")
                failed += 1
                continue

            fresh, ident, err = refresh_block(blk)
            if not fresh:
                print(f"  {RED}{n}{OFF}  {err}")
                failed += 1
                continue
            # Persist before anything else can run: the old refresh token is dead
            # from the moment that call returned.
            save_profile(n, fresh, ident)
            if n == cur:
                set_live_oauth(fresh)
        note = refresh_warning(fresh)
        tail = f"  {YELLOW}{note}{OFF}" if note else ""
        print(f"  {GREEN}{n}{OFF}  access {expiry_note(fresh)}{tail}")

    plan = relogin_plan({n: load_profile(n).get(OAUTH_KEY, {}) for n in list_profiles()})
    lines = relogin_lines(plan) if plan else []
    if lines:
        sys.stdout.flush()  # the results above go to stdout, these to stderr
        for i, line in enumerate(lines):
            info(f"{DIM}{'re-login' if i == 0 else '        '}  {line}{OFF}")
    if cur in names and yes:
        warn_running()
    if failed:
        sys.exit(1)


def cmd_use(name=None, yes=False, no_sync=False, **_):
    if not name:
        die(f"usage: {PROG} use <name>", USAGE_EXIT)
    if name in list_providers() and not os.path.exists(profile_path(name)):
        return cmd_provider_on(name=name)
    target = load_profile(name)
    blk = target.get(OAUTH_KEY)
    if not blk:
        die(f"'{name}' has no saved credentials. Re-save it with `{PROG} add {name}`.")

    live = live_oauth()
    if live and live.get("accessToken") == blk.get("accessToken"):
        set_active_ptr(name)
        left = clear_provider_ptr()
        if left:
            print(f"left {left}; new sessions start as {GREEN}{name}{OFF} ({target.get('email') or '?'})")
        else:
            print(f"already on {GREEN}{name}{OFF} ({target.get('email') or '?'})")
        return

    # The live token no longer equals the saved one once Claude Code has rotated
    # it, but that does not make this a different account. The live block is the
    # newer copy of the very profile we were asked for: keep it, and swap nothing.
    # Loading the saved block and putting it back would replace the rotated token
    # with one whose refresh token is already spent.
    if live and active_name(check_api=True) == name:
        if not no_sync:
            save_profile(name, live, {})
        set_active_ptr(name)
        left = clear_provider_ptr()
        if left:
            print(f"left {left}; new sessions start as {GREEN}{name}{OFF} ({target.get('email') or '?'})")
        else:
            print(f"already on {GREEN}{name}{OFF} ({target.get('email') or '?'})")
        return

    pids = run_pids(name)
    if pids and not yes:
        die(
            f"'{name}' is open in a `{PROG} run` session (pid {', '.join(map(str, pids))}). A second "
            f"copy of its login would rotate on its own and one of the two would be signed out. "
            f"Close that session first, or pass --yes."
        )

    # Hand over a credential that is usable as it lands. Claude Code would renew
    # an aged-out access token itself on the next start, but only if nothing
    # rewrites the store first - and until it does, `whoami` and the statusline
    # report a dead token for an account that is fine.
    rleft = refresh_left(blk)
    if not OFFLINE and expired(blk) and (rleft is None or rleft > 0):
        fresh, ident, err = refresh_block(blk)
        if fresh:
            save_profile(name, fresh, ident)
            target, blk = load_profile(name), fresh
        else:
            info(f"{DIM}could not renew '{name}' first ({err}); using the saved token{OFF}")

    # The network work is done. From here to the write we hold Claude Code's
    # refresh lock and read the live login again: it may have been refreshed
    # since we first looked, and the copy we save must be that one.
    with claude_lock():
        live = live_oauth()
        if live and not no_sync:
            sync_live_before_switch(live)
        set_live_oauth(blk)
    set_active_ptr(name)
    left = clear_provider_ptr()
    print(
        f"switched to {GREEN}{name}{OFF} "
        f"({target.get('email') or 'email unknown'}, {target.get('plan') or '?'})"
    )
    if left:
        info(f"{DIM}left {left}{OFF}")
    warn = refresh_warning(blk)
    if warn:
        info(f"{YELLOW}note:{OFF} {warn}")
    warn_running()
    print(f"{DIM}new `claude` sessions start as this account; open ones follow on their next message.{OFF}")


def cmd_provider_on(name=None, **_):
    """Run new sessions through a provider instead of a saved login."""
    if not name:
        die(f"usage: {PROG} <provider>", USAGE_EXIT)
    cmd = provider_command(name)
    if not cmd:
        die(f"'{name}' is not a provider. Register one with `{PROG} provider {name} <command>`.")
    if not shutil.which(cmd):
        die(f"'{cmd}' is not on your PATH, so `claude` could not start through '{name}'.")
    if active_provider() == name:
        print(f"already on {GREEN}{name}{OFF} (runs {cmd})")
        return
    set_provider_ptr(name)
    print(f"switched to {GREEN}{name}{OFF} (runs {cmd})")
    print(
        f"{DIM}the next `claude` you start runs through it; sessions already open keep what they "
        f"started with. `{PROG} off`, or hopping to an account, switches back.{OFF}"
    )


def cmd_provider(name=None, new=None, **_):
    """`hop provider` lists providers; `hop provider <name> <command>` registers one."""
    if not name:
        provs = list_providers()
        if not provs:
            info(f"No providers registered. Add one with:  {PROG} provider <name> <command>")
            return
        on = active_provider()
        for p in provs:
            print(f"{'*' if p == on else ' '} {p}  runs {provider_command(p) or '?'}")
        return
    if not new:
        die(f"usage: {PROG} provider <name> <command>", USAGE_EXIT)
    check_name(name)
    if name in COMMANDS or name in list_profiles():
        die(f"'{name}' is already a command or an account name; pick another.")
    if not re.match(r"^[A-Za-z0-9._/~+-]+$", new):
        die("the command must be one word with no arguments; put arguments in a small script.")
    profiles_dir()
    fd = os.open(provider_path(name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(new + "\n")
    print(f"registered provider {GREEN}{name}{OFF} (runs {new})")
    if not shutil.which(new):
        info(f"{YELLOW}note:{OFF} '{new}' is not on your PATH yet.")


def cmd_off(**_):
    """Leave the provider: new sessions use the saved login again."""
    left = clear_provider_ptr()
    if not left:
        print("no provider is on")
        return
    cur = active_name()
    print(f"left {left}; new sessions start as {GREEN}{cur}{OFF}" if cur
          else f"left {left}")


def cmd_add(name=None, yes=False, **_):
    if not name:
        die(f"usage: {PROG} add <name>", USAGE_EXIT)
    check_new_name(name)
    target = profile_path(name)
    # Kept in memory so a replace that turns out to be the wrong account can be
    # undone without leaving a .bak behind for `doctor` to complain about.
    prior = read_json(target) if os.path.exists(target) else None
    if prior is not None and not confirm(f"'{name}' already exists - replace it?", yes):
        die("aborted")
    if not shutil.which("claude"):
        die("`claude` is not on your PATH, so I can't drive the login. Install Claude Code first.")
    if not sys.stdin.isatty():
        die(f"adding an account needs a terminal - run `{PROG} add {name}` from one.")

    # A running session writes its own refreshed token into the credential store
    # without warning, which lands the wrong account under `name`. That is much
    # easier to prevent than to explain afterwards.
    pids = running_claude_pids()
    if pids and not yes:
        die(
            f"quit your other claude session(s) first - pid {', '.join(map(str, pids))}.\n"
            f"       While you are logging in, any one of them can write its own token back "
            f"into the credential store, and '{name}' would end up holding that account "
            f"instead.\n       Run with --yes to go ahead anyway."
        )

    prev_name = None
    with claude_lock():
        live = live_oauth()
        if live:
            prev_name = sync_live_before_switch(live)
        clear_live_oauth()
    if prev_name:
        info(f"{DIM}saved the current login ({prev_name}) before logging out{OFF}")
    info(f"\nStarting `claude` with no login. Sign in as the {BOLD}{name}{OFF} account")
    info("(use /login if it does not prompt), then exit with /exit or Ctrl-D.")
    info(
        f"{DIM}Your browser is already signed in as one of your other accounts. Paste the\n"
        f"login URL into a private window, or you will just re-authorise that one.{OFF}\n"
    )

    new: dict | None = None
    persisted = False

    def persist() -> bool:
        """Write whatever `claude` produced to disk. Idempotent.

        Deliberately does no network call first. Looking the account's email up
        takes up to CLAUDE_HOP_TIMEOUT seconds, and an interrupt anywhere in that
        window used to lose a credential that had already been issued - you were
        left logged in as an account with nothing saved for it. The identity
        lookup happens after the token is safely on disk; `list --verify` fills
        in an email that never made it.
        """
        nonlocal new, persisted
        if persisted:
            return True
        found = live_oauth()
        if not found or (live and found.get("accessToken") == live.get("accessToken")):
            # Nothing new was signed in - put back what was there. Never leave
            # the user logged out of everything.
            if live:
                with claude_lock(required=False):
                    set_live_oauth(live)
            return False
        new = found
        # A replaced profile must not keep the old account's email and plan
        # against the new account's token, even if we get killed right here.
        stale = dict.fromkeys(("email", "plan", "accountUuid", "org")) if prior else {}
        save_profile(name, found, stale)
        set_active_ptr(name)
        persisted = True
        return True

    old_signals = _guard_child_signals()
    hung_up = False
    try:
        try:
            subprocess.call(["claude"])
        except _TerminalGone:
            hung_up = True
    finally:
        try:
            saved = persist()
        finally:
            _restore_signals(old_signals)

    if not saved:
        info(f"{YELLOW}no new login found after that.{OFF} Nothing saved for '{name}'.")
        if prior is not None:
            info(f"The existing '{name}' profile was left as it was.")
        if live:
            prev = active_name()
            info("Your previous login was restored" + (f" ({prev})." if prev else "."))
        else:
            info("You were not logged in before either, so you still are not.")
        sys.exit(1)

    ident = identity(new)

    # A `claude` session that was already running refreshes its own token
    # straight into the credential store, and that block is not the login we
    # asked for. Saving it under `name` would file one account's live credential
    # under another account's name.
    prev_uuid = (
        read_json(profile_path(prev_name)).get("accountUuid")
        if prev_name and prev_name != name
        else None
    )
    if prev_uuid and ident.get("accountUuid") == prev_uuid:
        if prior is not None:
            write_json_secure(target, prior)
        else:
            os.remove(target)
        save_profile(prev_name, new, {})  # it is a newer token for that account
        set_active_ptr(prev_name)
        die(
            f"the credential store holds {ident.get('email') or prev_name} again, not a new "
            f"login - another running claude session refreshed it while we waited. Nothing "
            f"saved for '{name}'. Quit every claude session, then try again."
        )

    meta = {k: v for k, v in ident.items() if k != "tokenState"}
    if meta:
        save_profile(name, new, meta)
    print(f"saved and now active: {GREEN}{name}{OFF} ({ident.get('email') or 'email unknown'})")
    if not ident.get("accountUuid"):
        info(
            f"{YELLOW}note:{OFF} could not confirm which account that is, so '{name}' has no "
            f"email or plan recorded. Fill them in with:  {PROG} list --verify"
        )
    if hung_up:
        info(f"{DIM}(the terminal went away, but the login was saved){OFF}")


def cmd_rm(name=None, yes=False, **_):
    if not name:
        die(f"usage: {PROG} rm <name>", USAGE_EXIT)
    if name in list_providers() and not os.path.exists(profile_path(name)):
        if not confirm(f"delete provider '{name}'?", yes):
            die("aborted")
        os.remove(provider_path(name))
        if read_provider() == name:
            clear_provider_ptr()
        print(f"deleted {name}")
        return
    load_profile(name)  # existence check
    pids = run_pids(name)
    if pids:
        die(f"'{name}' is open in a `{PROG} run` session (pid {', '.join(map(str, pids))}). Close it first.")
    if name == active_name():
        info(
            f"{YELLOW}note:{OFF} '{name}' is the account you are logged in as right now; "
            f"deleting the saved copy does not log you out."
        )
    if not confirm(f"delete saved account '{name}'?", yes):
        die("aborted")
    for f in (profile_path(name), profile_path(name) + ".bak"):
        if os.path.exists(f):
            os.remove(f)
    remove_run_home(name)  # it holds a copy of the login
    if read_ptr() == name:
        os.remove(ACTIVE_PTR)
    print(f"deleted {name}")


def cmd_rename(name=None, new=None, **_):
    if not name or not new:
        die(f"usage: {PROG} rename <old> <new>", USAGE_EXIT)
    check_new_name(new)
    data = load_profile(name)
    if os.path.exists(profile_path(new)):
        die(f"'{new}' already exists")
    pids = run_pids(name)
    if pids:
        die(f"'{name}' is open in a `{PROG} run` session (pid {', '.join(map(str, pids))}). Close it first.")
    was_active = read_ptr() == name or active_name() == name
    data["name"] = new
    write_json_secure(profile_path(new), data)
    for f in (profile_path(name), profile_path(name) + ".bak"):
        if os.path.exists(f):
            os.remove(f)
    if os.path.isdir(run_home(name)):
        os.rename(run_home(name), run_home(new))
    if was_active:
        set_active_ptr(new)
    print(f"renamed {name} -> {new}")


def cmd_doctor(fix=False, verify=False, as_json=False, **_):
    problems: list[dict] = []

    def note(level: str, msg: str, fixed: str | None = None):
        problems.append({"level": level, "message": msg, "fixed": fixed})

    live = live_oauth()
    names = list_profiles()
    profiles = {n: peek_profile(n) for n in names}
    blocks = effective_blocks(profiles, active_name(), live)
    plan = relogin_plan(blocks)

    for var in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"):
        if os.environ.get(var):
            note("warn", f"${var} is set and overrides the saved login entirely")

    if os.path.isdir(ACCOUNTS):
        mode = os.stat(ACCOUNTS).st_mode & 0o777
        if mode & 0o077:
            if fix:
                os.chmod(ACCOUNTS, 0o700)
                note("warn", f"{ACCOUNTS} was {mode:o}", "chmod 700")
            else:
                note("error", f"{ACCOUNTS} is mode {mode:o}; it should be 700")

    for n in names:
        p = profile_path(n)
        mode = os.stat(p).st_mode & 0o777
        if mode & 0o077:
            if fix:
                os.chmod(p, 0o600)
                note("warn", f"{p} was {mode:o}", "chmod 600")
            else:
                note("error", f"{p} is mode {mode:o}; it should be 600")
        if not profiles[n]:
            note("error", f"{p} is empty or not valid JSON; delete it and run `{PROG} add {n}`")
            continue
        if not profiles[n].get(OAUTH_KEY, {}).get("accessToken"):
            note("error", f"'{n}' has no saved credentials; re-add it")
        warn = refresh_warning(blocks[n])
        if warn:
            note("warn", f"{n}: {warn}")
        # The live account's snapshot drifts every time Claude Code rotates the
        # token. Harmless until you hop away and back, which restores the old
        # one - so say it while it is still cheap to fix.
        saved = profiles[n].get(OAUTH_KEY, {})
        if blocks[n] is not saved and saved.get("accessToken") != blocks[n].get("accessToken"):
            where = "live login" if n == active_name() else "login in its run session"
            if fix:
                save_profile(n, blocks[n], {})
                note("warn", f"'{n}' saved copy was behind the {where}", "synced")
            else:
                note("warn", f"'{n}' saved copy is behind the {where}; --fix saves it")

    stale = []
    if os.path.isdir(ACCOUNTS):
        stale = [
            os.path.join(ACCOUNTS, f)
            for f in os.listdir(ACCOUNTS)
            if any(m in f for m in TMP_MARKERS) or f.endswith(".json.bak")
        ]
    for f in stale:
        if fix:
            os.remove(f)
            note("warn", f"stale file {f}", "removed")
        else:
            note("warn", f"stale file {f} (contains an old credential); --fix removes it")

    for d in claude_lock_dirs():
        try:
            age = time.time() - os.stat(d).st_mtime
        except OSError:
            continue
        if age > CLAUDE_LOCK_STALE_S:
            if fix:
                os.rmdir(d)
                note("warn", f"stale lock {d} ({humanise(age)} old)", "removed")
            else:
                note("warn", f"stale lock {d} ({humanise(age)} old, a run that died?); --fix removes it")

    provs = list_providers()
    for p in provs:
        cmd = provider_command(p)
        if not cmd:
            note("error", f"provider '{p}' has no command in {provider_path(p)}")
        elif not shutil.which(cmd):
            note("warn", f"provider '{p}' runs '{cmd}', which is not on your PATH")
    pptr = read_provider()
    if pptr and pptr not in provs:
        if fix:
            clear_provider_ptr()
            note("warn", f"provider pointer named '{pptr}', which is not registered", "cleared")
        else:
            note("error", f"provider pointer names '{pptr}', which is not registered; --fix clears it")

    ptr = read_ptr()
    if ptr and ptr not in names:
        note("error", f"active pointer names '{ptr}', which is not a saved account")
    if live and active_name(check_api=verify) is None:
        note("warn", f"the live login does not match any saved account; `{PROG} save <name>`")
    if not live:
        note("warn", "not logged in right now")

    pids = running_claude_pids()
    if pids:
        note("warn", f"{len(pids)} claude session(s) running; they may rewrite the credentials")

    if verify and names:
        for n, ident in identify_many(blocks).items():
            if not profiles[n]:
                continue  # already reported as unreadable above
            state = token_state(blocks[n], ident)
            if state in ("ok", "not checked", "stale (renews)", None):
                continue
            level = "warn" if state.startswith(("offline", "http")) else "error"
            note(level, f"'{n}' token state: {state}")

    if as_json:
        print(
            json.dumps(
                {
                    "backend": STORE.name,
                    "store": STORE.where,
                    "configDir": CLAUDE_DIR,
                    "accountsDir": ACCOUNTS,
                    "accounts": names,
                    "active": active_name(),
                    "provider": active_provider(),
                    "providers": provs,
                    "reloginPlan": plan,
                    "problems": problems,
                },
                indent=2,
            )
        )
    else:
        print(f"{BOLD}{PROG} {VERSION}{OFF}")
        print(f"  backend      {STORE.name} ({STORE.where})")
        print(f"  config dir   {CLAUDE_DIR}")
        print(f"  accounts     {ACCOUNTS} ({len(names)} saved)")
        print(f"  active       {active_name() or '(none)'}")
        if provs:
            print(f"  provider     {active_provider() or '(off)'} ({len(provs)} registered)")
        for i, line in enumerate(relogin_lines(plan) if plan else []):
            print(f"  {'re-login' if i == 0 else '        '}     {line}")
        print()
        if not problems:
            print(f"{GREEN}no problems found{OFF}")
        for p in problems:
            colour = RED if p["level"] == "error" else YELLOW
            suffix = f" {GREEN}[{p['fixed']}]{OFF}" if p["fixed"] else ""
            print(f"  {colour}{p['level']}{OFF}  {p['message']}{suffix}")
    if any(p["level"] == "error" and not p["fixed"] for p in problems):
        sys.exit(1)


def cmd_help(**_):
    print(__doc__.strip())


def cmd_version(**_):
    print(f"{PROG} {VERSION}")


# Second names for a command, kept working but not worth offering on TAB.
ALIASES = {"ls", "current", "switch", "new", "login", "remove", "delete", "mv", "check",
           "refresh", "providers"}


# Verbs and flags worth completing. Built from the tables below at call time, so
# a new command can't be added without tab-completion following it.
def _completion_words() -> tuple[str, str]:
    verbs = " ".join(k for k in COMMANDS if not k.startswith("-") and k not in ALIASES)
    flags = " ".join(sorted(k for k in FLAGS if k.startswith("--")))
    return verbs, flags


def cmd_shell_init(**_):
    """Print shell glue for a pip/pipx install: `eval "$(claudehop shell-init)"`.

    The repo installer writes shell/claudehop.sh instead, which also puts
    ~/.claude/bin on your PATH. A pip install already has the commands on the
    PATH, so all this adds is the `hop` alias and tab-completion.
    """
    verbs, flags = _completion_words()
    print(
        textwrap.dedent(
            f"""\
            # {PROG} {VERSION} — add to your shell rc:  eval "$({PROG} shell-init)"
            if [ -n "${{ZSH_VERSION:-}}" ]; then
              autoload -Uz +X bashcompinit 2>/dev/null && bashcompinit 2>/dev/null
            fi
            alias hop='{PROG}'
            claude() {{
              local _d="${{CLAUDE_ACCOUNTS_DIR:-${{CLAUDE_CONFIG_DIR:-$HOME/.claude}}/accounts}}" _p _c
              _p="$(cat "$_d/provider" 2>/dev/null)"
              if [ -n "$_p" ]; then
                _c="$(head -n 1 "$_d/$_p.provider" 2>/dev/null)"
                if [ -n "$_c" ] && command -v "$_c" >/dev/null 2>&1; then
                  command "$_c" "$@"
                  return
                fi
                echo "hop: provider '$_p' is on but '$_c' was not found; starting claude normally" >&2
              fi
              command claude "$@"
            }}
            _claudehop_names() {{
              local d="${{CLAUDE_ACCOUNTS_DIR:-${{CLAUDE_CONFIG_DIR:-$HOME/.claude}}/accounts}}" f n
              for f in "$d"/*.json; do
                [ -e "$f" ] || continue
                n="${{f##*/}}"
                printf '%s ' "${{n%.json}}"
              done
              for f in "$d"/*.provider; do
                [ -e "$f" ] || continue
                n="${{f##*/}}"
                printf '%s ' "${{n%.provider}}"
              done
            }}
            _claudehop_complete() {{
              local cur prev names
              cur="${{COMP_WORDS[COMP_CWORD]}}"
              prev="${{COMP_WORDS[COMP_CWORD-1]}}"
              names="$(_claudehop_names)"
              if [ "$COMP_CWORD" -eq 1 ]; then
                COMPREPLY=($(compgen -W "{verbs} $names" -- "$cur"))
              else
                case "$prev" in
                  use|switch|rm|remove|delete|rename|mv|save|add|new|login|renew|refresh|usage|run)
                    COMPREPLY=($(compgen -W "$names" -- "$cur")) ;;
                  *)
                    COMPREPLY=($(compgen -W "{flags}" -- "$cur")) ;;
                esac
              fi
            }}
            complete -F _claudehop_complete {PROG} hop 2>/dev/null
            """
        ).rstrip()
    )


COMMANDS = {
    "list": cmd_list, "ls": cmd_list,
    "use": cmd_use, "switch": cmd_use,
    "save": cmd_save,
    "add": cmd_add, "new": cmd_add, "login": cmd_add,
    "whoami": cmd_whoami, "current": cmd_whoami,
    "active": cmd_active,
    "sync": cmd_sync,
    "renew": cmd_renew, "refresh": cmd_renew,
    "rm": cmd_rm, "remove": cmd_rm, "delete": cmd_rm,
    "rename": cmd_rename, "mv": cmd_rename,
    "usage": cmd_usage,
    "run": cmd_run,
    "provider": cmd_provider, "providers": cmd_provider,
    "off": cmd_off,
    "doctor": cmd_doctor, "check": cmd_doctor,
    "shell-init": cmd_shell_init,
    "help": cmd_help, "-h": cmd_help, "--help": cmd_help,
    "version": cmd_version, "-V": cmd_version, "--version": cmd_version,
}

# Commands that only read; they skip the lock and never touch the store.
READ_ONLY = {cmd_list, cmd_whoami, cmd_active, cmd_help, cmd_version, cmd_shell_init}

FLAGS = {
    "-y": "yes", "--yes": "yes",
    "--verify": "verify",
    "--long": "long_", "-l": "long_",
    "--no-sync": "no_sync",
    "--json": "as_json",
    "--fix": "fix",
    "--no-color": "no_color",
    "--no-cache": "no_cache",
    "--fresh": "no_cache",
}


def main(argv: list[str]):
    # `run` hands everything after the account name to claude, flags included.
    if argv[:1] == ["run"]:
        rest = argv[2:]
        if rest[:1] == ["--"]:
            rest = rest[1:]
        cmd_run(name=argv[1] if len(argv) > 1 else None, rest=rest)
        return

    flags = {"yes": False, "verify": False, "long_": False, "no_sync": False,
             "as_json": False, "fix": False, "no_color": False, "no_cache": False}
    args: list[str] = []
    only_positional = False
    for a in argv:
        if only_positional:
            args.append(a)
        elif a == "--":
            only_positional = True
        elif a in FLAGS:
            flags[FLAGS[a]] = True
        elif a.startswith("-") and a not in COMMANDS:
            die(f"unknown option '{a}'. Try: {PROG} help", USAGE_EXIT)
        else:
            args.append(a)

    # Bare `hop` in a terminal asks which account you want; everywhere else -
    # a pipe, --json, a statusline - it stays a plain listing, and takes no lock.
    if not args and not flags["as_json"]:
        if sys.stdin.isatty() and sys.stdout.isatty():
            with lock():
                cmd_pick(**flags)
        else:
            cmd_list(**flags)
        return

    cmd = args[0] if args else "list"
    fn = COMMANDS.get(cmd)
    if not fn:
        # `claudehop work` is a shortcut for `claudehop use work`
        if VALID_NAME.match(cmd) and os.path.exists(profile_path(cmd)):
            fn, args = cmd_use, ["use", cmd]
        elif VALID_NAME.match(cmd) and os.path.exists(provider_path(cmd)):
            fn, args = cmd_provider_on, ["provider-on", cmd]
        else:
            known = ", ".join(list_profiles() + list_providers())
            hint = f" Saved accounts: {known}." if known else ""
            die(f"unknown command '{cmd}'. Try: {PROG} help{hint}", USAGE_EXIT)
    if len(args) > 3:
        die(f"too many arguments for '{cmd}'", USAGE_EXIT)

    def call():
        fn(
            name=args[1] if len(args) > 1 else None,
            new=args[2] if len(args) > 2 else None,
            **flags,
        )

    # `list --verify` writes the refreshed email/plan back, so it needs the lock too.
    if fn in READ_ONLY and not flags["verify"]:
        call()
    else:
        with lock():
            call()


def _run() -> int:
    try:
        main(sys.argv[1:])
    except SystemExit as e:
        if isinstance(e.code, int):
            return e.code
        return 0 if e.code is None else 1
    return 0


def console_main() -> int:
    """Entry point for the `claudehop` and `hop` commands, and for `python -m`."""
    try:
        code = _run()
        sys.stdout.flush()
    except KeyboardInterrupt:
        code = 130
    except BrokenPipeError:
        # `claudehop list | head` — say nothing, leave no traceback.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        code = 0
    return code


if __name__ == "__main__":
    sys.exit(console_main())
