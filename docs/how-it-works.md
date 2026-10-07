# How it works

What claudehop does to Claude Code's login, why it is built that way, and what was measured to
justify it. Claims about Claude Code's behaviour name the version they were checked on.

Claude Code keeps the live login under the `claudeAiOauth` key of its credential
store. This tool keeps one saved copy of that block per account in
`~/.claude/accounts/<name>.json` and swaps the active one in and out. The
`mcpOAuth` key in the same store, which holds your Vercel/Neon/etc. MCP logins, is left
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
the first refresh, and then loses the refreshed token when you switch away. So
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
  once; `hop run` can. On macOS claude-swap's documentation says the keychain
  read is cached for about half a minute first; that is not tested here.
- `/login` opens your default browser, which is already signed in as somebody.
  Paste the URL into an incognito window to authenticate as a different account.
- `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` in the environment override
  the saved login entirely. `whoami` and `doctor` warn when either is set.
- `--long` showing `expired (auto-renews)` under `TOKEN` is normal. The access
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
to do them all on the day the earliest one comes due. After that they share one
date and it's one sitting a month. `doctor` works this out for you:

```
$ hop doctor
  accounts     /home/you/.claude/accounts (4 saved)
  active       work
  re-login     by 2026-08-30 (work); the other 3 by 2026-09-04
               windows are ~30d from login and do not slide, so re-login all 4 on
               2026-08-30 and they collapse to one date
```

You also get a per-account warning starting 14 days out. `doctor --json` carries
the same dates under `reloginPlan`, if you want to hang a reminder off them.
`extras/` has two ready-made ones: a statusline snippet that counts down the last
week, and a systemd user timer. The timer renews the saved tokens daily and
raises a desktop notification before the earliest window closes.

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

- those tokens carry inference scope only: `/api/oauth/profile` answers `403 OAuth
  token does not meet scope requirement`, so you can't tell whose token you're
  holding or whether it's still good;
- they expire, and a dead one looks exactly like a live one until a request fails;
- it's per-shell, so every terminal has to be primed before `claude` starts.

Swapping the real credential block avoids all three and matches what Claude Code
already does to itself.
