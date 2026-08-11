<p align="center">
  <img src="https://raw.githubusercontent.com/psychofict/claudehop/master/assets/cover.png" alt="claudehop — hop Claude Code between accounts" width="560">
</p>

<h1 align="center">claudehop</h1>

<p align="center">
  <b>Hop Claude Code between several Claude accounts without logging in again.</b><br>
  Personal Max account in one terminal, work Team seat in another —
  <i>two separate usage pools, one machine, no browser round-trip.</i>
</p>

<p align="center">
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

Then start a new `claude`. That's it — that's the whole tool.

If you'd rather not read a menu, `hop home` goes straight there. Sessions you
already have open keep the account they started with; only new ones pick up the
change.

## Install

```bash
git clone https://github.com/psychofict/claudehop.git
cd claudehop
./install.sh          # symlinks into ~/.claude, adds one line to your rc file
```

Then open a new terminal. `hop` and `claudehop` are the same command.

`./install.sh --copy` installs copies instead of symlinks, `--no-rc` skips the
shell wiring, `--uninstall` reverses it. None of them ever touch
`~/.claude/accounts/`, where the credentials live.

It's also a normal Python package if you'd rather manage it that way — one
module, no dependencies:

```bash
pipx install .                      # both commands land on your PATH
eval "$(claudehop shell-init)"      # optional: the `hop` alias + tab-completion
```

Requires Python 3.9+ and Claude Code. Linux and macOS.

## Adding an account

```bash
hop add work
```

Quit your other `claude` sessions first — `add` will stop and tell you if you
haven't, because a session left running can write its own token back into the
credential store mid-login and you'd end up with the wrong account saved under
that name.

`add` then starts `claude` with no login so you can `/login`, and saves whatever
that produces when you exit with `/exit`. **Paste the login URL into a private
browser window.** Your normal browser is already signed in as one of your other
accounts and will authorise that one without asking.

If the login produces nothing — you changed your mind, you hit Ctrl-C — your
previous credentials come back. If it does produce a login, that login is saved
even if the terminal dies on the way out.

Already logged in by hand? `hop save work` names whatever is live right now.

## Everything else

```bash
hop whoami           # who am I right now (asks the API)
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

## Gotchas

- Switching affects **new** `claude` processes. Sessions already running keep the
  account they started with, and will rewrite the credential store when their
  token refreshes — which can silently undo a switch. `claudehop` prints the
  PIDs it finds; quit them for a clean switch.
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

The refresh token is good for roughly 30 days from the `/login` that issued it,
and **using the account does not extend it.** Measured 2026-08-06 across four
accounts: one had its access token reissued that morning and its refresh window
still ended 30 days after its first login, not 30 days after the refresh. So this
is a hard monthly expiry per account, and nothing on this side can lengthen it —
it's set by the OAuth server. `claude setup-token` is not a way around it either;
those tokens expire too, and carry inference scope only.

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
test/test-switch.sh          99 checks against a throwaway config dir, no network
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
