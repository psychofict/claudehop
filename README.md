<p align="center">
  <img src="https://raw.githubusercontent.com/psychofict/claudehop/master/assets/cover.png" alt="claudehop — hop Claude Code between accounts" width="560">
</p>

<h1 align="center">claudehop</h1>

<p align="center">
  <b>Hop Claude Code between several Claude accounts without logging in again.</b><br>
  Personal Max account in the morning, work Team seat in the afternoon —
  <i>two separate usage pools, one machine, no browser round-trip.</i>
</p>

<p align="center">
  <a href="https://pypi.org/project/claudehop-cli/"><img src="https://img.shields.io/pypi/v/claudehop-cli.svg?color=FC5F00&label=pypi" alt="PyPI"></a>
  <a href="https://github.com/psychofict/claudehop/actions/workflows/ci.yml"><img src="https://github.com/psychofict/claudehop/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/psychofict/claudehop/blob/master/LICENSE"><img src="https://img.shields.io/badge/licence-MIT-FC5F00.svg" alt="Licence: MIT"></a>
  <img src="https://img.shields.io/badge/python-3.9%2B-1D1009.svg" alt="Python 3.9+">
  <img src="https://img.shields.io/badge/dependencies-none-1D1009.svg" alt="No dependencies">
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="https://github.com/psychofict/claudehop/blob/master/CHANGELOG.md">Changelog</a> ·
  <a href="https://github.com/psychofict/claudehop/blob/master/SECURITY.md">Security</a>
</p>

---

## Switching accounts

Run `hop`, press a number.

```
$ hop
      NAME  EMAIL           PLAN
1.    home  me@gmail.com    max
2. *  work  me@company.com  team

hop to which? [1-2, Enter to stay] 1
switched to home (me@gmail.com, max)
```

Claude Code reads its login again before every message, so a hop reaches the
`claude` sessions you already have open too, on their next message. That's it —
that's the whole tool.

If you'd rather not read a menu, `hop home` goes straight there.

## Install

```bash
pipx install claudehop-cli          # or: pip install --user claudehop-cli
eval "$(claudehop shell-init)"      # the `hop` alias + tab-completion
```

Put that `eval` line in your `~/.bashrc` or `~/.zshrc` and open a new terminal.
`hop` and `claudehop` are the same command. (The distribution carries the `-cli`
suffix because PyPI holds the bare name too close to an unrelated project. The
commands don't.)

Or from a clone, if you'd rather have it symlinked into `~/.claude` with the
shell glue written for you:

```bash
git clone https://github.com/psychofict/claudehop.git
cd claudehop
./install.sh          # symlinks into ~/.claude, adds one line to your rc file
```

`./install.sh --copy` installs copies instead of symlinks, `--no-rc` skips the
shell wiring, `--uninstall` reverses it. None of them ever touch
`~/.claude/accounts/`, where the credentials live.

Requires Python 3.9+ and Claude Code. Linux and macOS. One module, no
dependencies.

## Adding an account

```bash
hop add work
```

Quit your other `claude` sessions first — `add` will stop and tell you if you
haven't, because a session left running can write its own token back into the
credential store mid-login and you'd end up with the wrong account saved under
that name.

Don't `/logout` first. `add` clears the local login itself, and a `/logout` may
also revoke the refresh token of the account you are leaving on Anthropic's side
(claude-swap's documentation reports this; I have not tested it).

`add` then starts `claude` with no login so you can `/login`, and saves whatever
that produces when you exit with `/exit`. **Paste the login URL into a private
browser window.** Your normal browser is already signed in as one of your other
accounts and will authorise that one without asking.

If the login produces nothing — you changed your mind, you hit Ctrl-C — your
previous credentials come back. If it does produce a login, that login is saved
even if the terminal dies on the way out.

Already logged in by hand? `hop save work` names whatever is live right now.

## Providers: Bedrock, Vertex, a gateway

Some ways of running Claude Code are not a login at all: Amazon Bedrock and
Vertex read environment variables, and a gateway is a base URL. Write a small
launcher script that sets them and runs `claude "$@"`, register it once, and
hop to it like an account:

```bash
hop provider bedrock claude-bedrock   # name, then the command to run instead of `claude`
hop bedrock                           # new `claude` commands go through the launcher
hop off                               # back to your saved login
```

Hopping to an account (`hop work`) also switches a provider off. Saved logins
are never touched, so a provider works even when a login has expired. `hop`
lists providers under your accounts, `hop active` prints the provider's name
while one is on (`hop active --json` keeps the account too), and `hop doctor`
reports a launcher that has gone missing.

The switch is read by a `claude` function in the shell glue, so it applies to
terminals that have loaded it (`source ~/.claude/claudehop.sh`, or open a new
one). Sessions that are already running keep what they started with. The
command must be a single word; put arguments in the launcher.

## Everything else

```bash
hop whoami           # who am I right now (asks the API)
hop usage            # 5-hour and 7-day usage of every account
hop renew            # refresh the saved tokens; one name, or all of them
hop --long           # add token expiry and save dates to the listing
hop list --verify    # check every saved token against the API
hop rm <name>        # delete a saved account (does not log you out)
hop rename <a> <b>
hop doctor           # check the setup; --fix repairs what it can
hop shell-init       # shell glue for a pip install: alias + tab-completion
```

`--json` on `list`, `whoami`, `active` and `doctor` gives machine-readable
output with no secrets in it, for scripts and statuslines. `hop active` prints
just the active name with no network call. `hop use <name>` is the long spelling
of `hop <name>`, and `hop sync` writes the live login back to its own file.

## Usage

```
$ hop usage
   NAME   5 HOURS            7 DAYS             NOTE
   home   98%  resets 24m    61%  resets 4d23h
*  work   42%  resets 2h14m  18%  resets 3d4h
```

How much of each account's 5-hour and 7-day allowance is spent, and when each
window resets, read from the endpoint behind Claude Code's own `/usage`. That
endpoint limits clients other than Claude Code, and a throttled token can stay
blocked for about half an hour (a `Retry-After` of 1524 seconds has been seen).
So `hop usage` asks only when you run it, remembers the last good reading in
`accounts/.usage-cache` (percentages and times, no tokens), and does not ask
again until the server's `Retry-After` has passed. A throttled row shows the
last reading and its age. Nothing polls in the background, and an account whose
access token has aged out is left alone: `hop renew <name>` refreshes it.
`hop usage <name>` checks one account, `--json` is for scripts.

## How it works

Claude Code keeps the live login under the `claudeAiOauth` key of its credential
store. This tool keeps one saved copy of that block per account in
`~/.claude/accounts/<name>.json` and swaps the active one in and out. The
`mcpOAuth` key in the same store — your Vercel/Neon/etc. MCP logins — is left
alone, so switching accounts doesn't sign you out of anything else.

| | credential store |
|---|---|
| Linux | `~/.claude/.credentials.json` |
| macOS | login keychain item `Claude Code-credentials`, falling back to the file |

The backend is detected from whichever one currently holds a login. Force it
with `CLAUDE_HOP_BACKEND=file` or `=keychain` if you need to.

Nothing else needs patching. Account identity in `~/.claude.json`
(`oauthAccount`) is re-fetched from the API by Claude Code at startup: put a
bogus email in there, start a session, and it comes back corrected. So swapping
the credential is the whole job.

Identity, plan and token checks come from `GET /api/oauth/profile` with the
account's own bearer token. Set `CLAUDE_HOP_OFFLINE=1` to skip every API call.

### Two details that make or break it

**Access tokens rotate.** Claude Code refreshes them every few hours and writes
the new one straight into the credential store. A switcher that identifies the
active profile by comparing token values therefore stops recognising it after
the first refresh — and then loses the refreshed token when you switch away. So
the active profile is tracked in `accounts/active` and confirmed against the
account UUID from the API, and every switch writes the live block back to its
profile before loading the next one.

**A login you can't identify is stashed, never dropped.** If the live
credentials match no saved profile (you ran `/login` by hand, say), switching
saves them under a name derived from the account's email first. You can always
get back to a session you'd otherwise have to re-authenticate.

### It takes Claude Code's refresh lock

While Claude Code refreshes a token it holds two lock directories
(`~/.claude/.oauth_refresh.lock` and `~/.claude.lock`), reads the login, calls
the token endpoint and writes the result back. A switch that landed in that
window would be overwritten, and the account you had just left would be saved
with a refresh token the server had already retired. So every command that
replaces the live login holds the same two locks, in Claude Code's order, for
the length of the file read and write, with the network calls done first. If
Claude Code is mid-refresh it waits up to 9 seconds, then stops with nothing
changed (`CLAUDE_HOP_LOCK_WAIT` sets the wait). `doctor` reports a lock left
behind by a run that died.

Claude Code's side was checked on 2.1.284 by tracing it in a sandbox with the
network cut off: it waits when another tool holds either lock and never removes
one younger than 60 seconds. It is not a documented interface, so a later
version may change it.

## Gotchas

- A hop moves **every** running `claude`, not only new ones. Claude Code reads
  the credential store again before each message: with a fake endpoint, a
  session sent its next message with the new login about two seconds after the
  swap (Linux, Claude Code 2.1.284, headless mode). So a conversation already
  under way changes account on its next message, moves to the new account's
  usage, and starts a new prompt cache. `claudehop` lists the sessions it finds
  when you hop. It also means one `hop` cannot give two terminals two accounts at
  once; for that, run one of them under its own `CLAUDE_CONFIG_DIR`. On macOS
  claude-swap's documentation says the keychain read is cached for about half a
  minute first; that is not tested here.
- `/login` opens your default browser, which is already signed in as somebody.
  Paste the URL into an incognito window to authenticate as a different account.
- `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` in the environment override
  the saved login entirely. `whoami` and `doctor` warn when either is set.
- `--long` showing `expired (auto-renews)` under `TOKEN` is normal — the access
  token is short lived and Claude Code renews it from the refresh token.
  `list --verify` prints `stale (renews)` for the same reason. What actually
  matters is the refresh token; see below. This is why the default listing
  doesn't show either of them.
- Each account still has its own rate limits and its own terms. This moves your
  own logins between your own terminals; it is not a way to pool quota.

## Every account needs a real login about once a month

The refresh token is good for up to 30 days from the `/login` that issued it,
and **using the account does not extend it.** Measured 2026-08-06 across four
accounts: one had its access token reissued that morning and its refresh window
still ended 30 days after its first login, not 30 days after the refresh.

Confirmed again 2026-08-31 by refreshing a saved token by hand. The call does
rotate the refresh token, so it is easy to assume the clock rotates with it, but
the reply came back with `refresh_token_expires_in` landing on the same
wall-clock minute the old token was already going to die on. Access tokens are a
flat 8 hours. A fresh login can also hand back less than the full 30 days: one
account re-logged-in that morning got 27.5.

So this is a hard monthly expiry per account, nothing on this side can lengthen
it, and `hop renew` is honest about that. Renewing keeps the saved copies usable
and current, which is worth doing, but only `hop add <name>` resets the clock.
`claude setup-token` is not a way around it either; those tokens expire too, and
carry inference scope only.

With several accounts the dates drift apart and you get a browser round-trip per
account per month. Logging in early resets the whole 30 days, so the cheap move is
to do them all on the day the earliest one comes due — after that they share one
date and it's one sitting a month. `doctor` works this out for you:

```
$ hop doctor
  accounts     /home/you/.claude/accounts (4 saved)
  active       work
  re-login     by 2026-08-30 (work); the other 3 by 2026-09-04
               windows are ~30d from login and do not slide, so re-login all 4 on
               2026-08-30 and they collapse to one date
```

You also get a per-account warning starting 14 days out, and `doctor --json`
carries the same thing under `reloginPlan` if you want to hang a reminder off it.
`extras/` has two ready-made ways to hang one: a statusline snippet that counts
down the last week, and a systemd user timer that renews the saved tokens daily
and raises a desktop notification before the earliest window closes.

One thing worth knowing about how this is reported. A saved profile is a snapshot
from the last hop or sync, but Claude Code rotates the live token behind it every
few hours and a browser re-login replaces it outright. For whichever account is
active, the credential store is therefore newer than its own saved copy, and that
is what `list` and `doctor` judge it by. Reading the snapshot instead is how a
perfectly good login gets reported as expired. `doctor` tells you when the saved
copy has fallen behind, and `--fix` syncs it.

## Why not `claude setup-token`

The obvious approach is a long-lived token per account exported as
`CLAUDE_CODE_OAUTH_TOKEN`. It doesn't hold up:

- those tokens carry inference scope only — `/api/oauth/profile` answers `403 OAuth
  token does not meet scope requirement`, so you can't tell whose token you're
  holding or whether it's still good;
- they expire, and a dead one looks exactly like a live one until a request fails;
- it's per-shell, so every terminal has to be primed before `claude` starts.

Swapping the real credential block avoids all three and matches what Claude Code
already does to itself.

## Security

Saved credentials are real, live Claude logins. `accounts/` is `700`, every
profile is `600`, and writes are atomic. Nothing is ever sent anywhere except
`api.anthropic.com` to resolve an email and plan. See
[SECURITY.md](https://github.com/psychofict/claudehop/blob/master/SECURITY.md)
for the threat model and how to report a problem.

## Files

```
claudehop.py                 the tool (python3, stdlib only)
shell/claudehop.sh           PATH, tab-completion, back-compat aliases
extras/statusline-snippet.sh show the active account in the Claude Code statusline
install.sh                   symlink/copy into ~/.claude, wire up the rc file
pyproject.toml               packaging: one module, no dependencies, two commands
test/test-switch.sh          about 150 checks against a throwaway config dir, no network
assets/                      logo, icon, cover and social preview (svg sources + png)
```

## Tests

```bash
./test/test-switch.sh
```

Runs entirely inside a temp dir with fake credentials — it never reads or writes
a real account, and never touches the network. Covers the swap, mcpOAuth
preservation, token rotation, the stash path, concurrent switches, the macOS
keychain backend (through a stand-in `security`), `add` rolling back a failed
login, `add` surviving a teardown after a successful one, the refresh race, JSON
output, table layout, housekeeping and file permissions.

## Contributing

Issues and pull requests welcome — see
[CONTRIBUTING.md](https://github.com/psychofict/claudehop/blob/master/CONTRIBUTING.md).
If `claudehop` saved you a browser round-trip this morning, a ⭐ on
[GitHub](https://github.com/psychofict/claudehop) helps others find it.

## Licence

MIT. Not affiliated with, endorsed by, or sponsored by Anthropic. "Claude" and
"Claude Code" are trademarks of Anthropic, PBC, used here only to say what this
works with.

---

<p align="center">
  Made by <a href="https://ebenworks.co/">Ebenworks</a>
</p>
