# claudehop

Hop Claude Code between several Claude accounts without logging in again.

[![CI](https://github.com/psychofict/claudehop/actions/workflows/ci.yml/badge.svg)](https://github.com/psychofict/claudehop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

```
$ hop
   NAME  EMAIL           PLAN  TOKEN    SAVED
   home  me@gmail.com    max   5h left  2026-08-03
*  work  me@company.com  team  7h left  2026-08-03

$ hop home
switched to home (me@gmail.com, max)
```

Personal Max account in one terminal, work Team seat in another — two separate
usage pools, one machine, no browser round-trip to move between them.

One Python file, standard library only. Nothing to build, nothing to install
from a package registry.

## Install

```bash
git clone https://github.com/psychofict/claudehop.git
cd claudehop
./install.sh          # symlinks into ~/.claude, adds one line to your rc file
```

Then open a new terminal.

`./install.sh --copy` installs copies instead of symlinks, `--no-rc` skips the
shell wiring, `--uninstall` reverses it. None of them ever touch
`~/.claude/accounts/`, where the credentials live.

Requires Python 3.9+ and Claude Code. Linux and macOS.

## Use

```bash
claudehop                  # list saved accounts, * marks the active one
claudehop add work         # log in as a new account and save it
claudehop use work         # switch — or just: claudehop work
claudehop whoami           # who am I right now (asks the API)
claudehop active           # just the active account name, no network
claudehop list --verify    # check every saved token against the API
claudehop save <name>      # save the current login under a name
claudehop sync             # push the live login back into its saved file
claudehop rm <name>        # delete a saved account (does not log you out)
claudehop rename <a> <b>
claudehop doctor           # check the setup; --fix repairs what it can
```

`--json` on `list`, `whoami`, `active` and `doctor` gives machine-readable
output with no secrets in it, for scripts and statuslines.

Adding an account runs `claude` for you so you can `/login`; on exit it saves
whatever credentials that produced. If you already logged in by hand, just
`claudehop save <name>`. If the login produces nothing — you changed your mind,
you hit Ctrl-C — your previous credentials are put back.

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
- `TOKEN` showing `expired (auto-renews)` is normal — the access token is short
  lived and Claude Code renews it from the refresh token. `list --verify` prints
  `stale (renews)` for the same reason. What actually matters is the refresh
  token, and you get a warning a week before that one runs out.
- Each account still has its own rate limits and its own terms. This moves your
  own logins between your own terminals; it is not a way to pool quota.

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
`api.anthropic.com` to resolve an email and plan. See [SECURITY.md](SECURITY.md)
for the threat model and how to report a problem.

## Files

```
bin/claudehop              the tool (python3, stdlib only)
shell/claudehop.sh           PATH, tab-completion, back-compat aliases
extras/statusline-snippet.sh show the active account in the Claude Code statusline
install.sh                   symlink/copy into ~/.claude, wire up the rc file
test/test-switch.sh          62 checks against a throwaway config dir, no network
```

## Tests

```bash
./test/test-switch.sh
```

Runs entirely inside a temp dir with fake credentials — it never reads or writes
a real account, and never touches the network. Covers the swap, mcpOAuth
preservation, token rotation, the stash path, concurrent switches, the macOS
keychain backend (through a stand-in `security`), `add` rolling back a failed
login, JSON output, table layout, housekeeping and file permissions.

## Contributing

Issues and pull requests welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT. Not affiliated with Anthropic.
