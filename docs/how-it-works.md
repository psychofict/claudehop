# How it works

claudehop swaps one block of Claude Code's credential store, under Claude Code's own refresh lock,
and never drops a login it cannot get back. This page says what it touches, why it is built that
way, and what was measured to justify it. Claims about Claude Code's behaviour name the version
they were checked on. It is not a documented interface, so a later version may behave differently.

## What gets swapped

Claude Code keeps the live login under the `claudeAiOauth` key of its credential store. claudehop
keeps one saved copy of that block per account in `~/.claude/accounts/<name>.json` and swaps the
active one in and out. The `mcpOAuth` key in the same store, which holds your MCP server logins, is
left alone, so switching accounts doesn't sign you out of anything else.

| | credential store |
|---|---|
| Linux | `~/.claude/.credentials.json` |
| macOS | login keychain item `Claude Code-credentials`, falling back to the file |

The backend is detected from whichever one currently holds a login. Force it with
`CLAUDE_HOP_BACKEND=file` or `=keychain` if you need to.

Nothing else needs patching. Claude Code fetches the account identity in `~/.claude.json`
(`oauthAccount`) from the API again at startup: put a bogus email in there, start a session, and it
comes back corrected. So swapping the credential is the whole job.

Identity, plan and token checks come from `GET /api/oauth/profile` with the account's own bearer
token. Set `CLAUDE_HOP_OFFLINE=1` to skip every API call.

## Never losing a login

A login lost by mistake costs a browser round-trip and, sometimes, a device-approval email. Four
rules prevent it.

**Access tokens rotate.** Claude Code refreshes them every few hours and writes the new one
straight into the credential store. A switcher that identifies the active profile by comparing
token values stops recognising it after the first refresh, and then loses the refreshed token when
you switch away. So the active profile is tracked in `accounts/active` and confirmed against the
account UUID from the API. Every switch writes the live block back to its profile before loading the
next one.

**A login that can't be identified is stashed, never dropped.** If the live credentials match no
saved profile (you ran `/login` by hand, say), switching saves them under a name taken from the
account's email first. You can always get back to a session you would otherwise have to log in to
again.

**A refresh token is single-use.** Renewing trades the refresh token for a new pair, and the old one
stops working the moment the server answers. So every renewal is written to disk before anything else
happens. A login that two places could each renew, such as the live login or an account open in a
`hop run` session, is only ever renewed by the Claude Code that holds it.

**The newer copy wins.** A `hop run` home keeps the login its session last used, while `renew` and
`usage` may renew the saved copy in the meantime. When the two differ, the one issued later is kept;
access tokens last a flat 8 hours, so a later expiry means a later token. Before 1.9.0 an ended
session's older login could be copied back over a renewed profile, which put a retired refresh token
in the saved copy and signed the account out.

## It takes Claude Code's refresh lock

While Claude Code refreshes a token it holds two lock directories (`~/.claude/.oauth_refresh.lock`
and `~/.claude.lock`), reads the login, calls the token endpoint and writes the result back. A
switch that landed in that window would be overwritten, and the account you had just left would be
saved with a refresh token the server had already retired. So every command that replaces the live
login holds the same two locks, in Claude Code's order, for the length of the file read and write,
with the network calls done first. If Claude Code is mid-refresh it waits up to 9 seconds, then
stops with nothing changed (`CLAUDE_HOP_LOCK_WAIT` sets the wait). `doctor` reports a lock left
behind by a run that died.

Claude Code's side was checked on 2.1.284 by tracing it with `strace` in a sandbox with the network
cut off. The locks follow the proper-lockfile convention: one older than 60 seconds counts as stale,
and the holder touches it every 5 seconds. When another tool holds either lock, Claude Code waits
(six attempts over about seven seconds, then it tries again later) and never removes one younger
than 60 seconds.

## Open sessions follow a hop

Claude Code reads the credential store again before each message. It does not hold the login for
the life of a session. Measured on Linux with Claude Code 2.1.284, in a sandbox with the network cut
off, against a local fake server that records each request's bearer token:

| Mode | First message | Next message after an atomic swap of the file |
|---|---|---|
| Headless (`claude -p`, stream-json input) | old login | new login, 2 seconds after the swap |
| Interactive screen, in a pseudo-terminal | old login | new login, 0.9 seconds after the swap, in 3 runs of 3 |

Claude Code left the swapped file as it was, and its own side request sent with each message
followed the swap too. So a hop moves every running `claude`, and a conversation already under way
changes account on its next message and starts spending the new account's usage. Its prompt cache
very likely starts over as well (not measured). It also means one hop cannot give two terminals two
accounts at once; `hop run` can.

The interactive measurement is in
[`docs/experiments/session-follows-swap.py`](experiments/session-follows-swap.py), so it can be
repeated on a newer version. macOS is not measured: there the login is in the keychain, and
claude-swap's documentation says the keychain read is cached for about half a minute.
[Issue 1](https://github.com/psychofict/claudehop/issues/1) says how to check it.

## Reading usage

`hop usage` reads `GET /api/oauth/usage`, the endpoint behind Claude Code's own `/usage`, with the
account's bearer token. The reply has a `five_hour` and a `seven_day` window, plus per-model windows
under code names, each with a `utilization` in percent and a `resets_at` time.

The endpoint budgets other clients. On 6 October 2026 a token got `429` on its first call, with a
`Retry-After` of about 25 minutes that counted down to a fixed time and was not extended by asking
again. By 13 October a 429 held a token for up to an hour. So `hop usage` asks only when you run it,
keeps the last good reading, and never asks before the `Retry-After` has passed. Requests say they
come from claudehop; the tool does not pose as Claude Code to get round the budget.

Idle tokens expire too. An access token lasts 8 hours, and the endpoint refuses an expired one. A
login renewed once a day can therefore be read for only a third of it. `hop usage` renews an idle
account's token before asking, under the single-use rule above.

Team seats report weekly limits differently. Measured on 13 October 2026: for a Team seat,
`seven_day` is `null`. Its weekly limits, often scoped to one model, are rows in a `limits` list. Each
row has a `kind` (`session`, `weekly_all` or `weekly_scoped`), a `percent`, a `resets_at` and the
model it covers. claudehop keeps those rows, shows the fullest in the 7-day column, and treats only an
all-model one as a limit that stops a login.

Every reply carries the figures too. In stream-json mode Claude Code emits a `rate_limit_event`
whose `unifiedWindows` give each window's use as a fraction and its reset as a Unix time. `--probe`
uses that. It runs `claude -p` once with the smallest model, the account's access token in
`CLAUDE_CODE_OAUTH_TOKEN`, an empty throwaway config home, no tools, no MCP servers and no
transcript. In that mode Claude Code neither refreshes nor writes a login, so no saved copy can be
rotated out from under anybody. Measured on 13 October 2026: two to three seconds, about US$0.01 at
API prices. The request counts against the account, and on an account whose 5-hour window has not
started, it starts one. That is why `--probe` runs only when you ask, and `hop next` uses it only for
a login whose figure it cannot get otherwise.

## Every account needs a real login about once a month

The refresh token is good for up to 30 days from the `/login` that issued it, and using the account
does not extend it. Measured 2026-08-06 across four accounts: one had its access token reissued that
morning and its refresh window still ended 30 days after its first login, not 30 days after the
refresh.

Confirmed again 2026-08-31 by refreshing a saved token by hand. The call does rotate the refresh
token, so it is easy to assume the clock rotates with it, but the reply came back with
`refresh_token_expires_in` landing on the same wall-clock minute the old token was already going to
die on. Access tokens are a flat 8 hours. A fresh login can also hand back less than the full 30
days: one account logged in again that morning got 27.5.

So this is a hard monthly expiry per account, nothing on this side can lengthen it, and `hop renew`
is honest about that. Renewing keeps the saved copies usable and current, which is worth doing, but
only `hop add <name>` resets the clock. `claude setup-token` is not a way around it either; those
tokens expire too, and carry inference scope only.

With several accounts the dates drift apart and you get a browser round-trip per account per month.
Logging in early resets the whole 30 days, so the cheap move is to do them all on the day the
earliest one comes due. After that they share one date and it's one sitting a month. `doctor` works
this out for you:

```
$ hop doctor
  accounts     /home/you/.claude/accounts (3 saved)
  active       work
  re-login     by 2026-11-01 (work); the other 2 by 2026-11-05
               windows are ~30d from login and do not slide, so re-login all 3 on
               2026-11-01 and they collapse to one date
```

You also get a per-account warning starting 14 days out. `doctor --json` carries the same dates under
`reloginPlan`, if you want to hang a reminder off them. The
[command reference](commands.md#keeping-logins-healthy) shows how to install the two ready-made
reminders in `extras/`: a daily systemd timer that renews the saved logins and puts up a desktop
notification, and a statusline countdown for the last week.

A saved profile is a snapshot from the last hop or sync, but Claude Code rotates the live token
behind it every few hours and a browser login replaces it outright. For whichever account is
active, the credential store is therefore newer than its own saved copy, and that is what `list` and
`doctor` judge it by. Reading the snapshot instead is how a perfectly good login gets reported as
expired. `doctor` tells you when the saved copy has fallen behind, and `--fix` syncs it.

## Why not `claude setup-token`

The obvious approach is a long-lived token per account exported as `CLAUDE_CODE_OAUTH_TOKEN`. It
doesn't hold up:

- those tokens carry inference scope only: `/api/oauth/profile` answers `403 OAuth token does not
  meet scope requirement`, so you can't tell whose token you're holding or whether it's still good;
- they expire, and a dead one looks exactly like a live one until a request fails;
- it's per shell, so every terminal has to be primed before `claude` starts.

Swapping the real credential block avoids all three and matches what Claude Code already does to
itself. `--probe` borrows the variable for a single request only, with a normal access token.

## Reading claudehop's state from another tool

A status bar, a tray widget or a script can follow claudehop without calling it, by reading a few
files in the accounts folder (`~/.claude/accounts`, or `CLAUDE_ACCOUNTS_DIR`). None of these holds a
token. Read them and leave them alone; only claudehop writes them.

| File | What it holds |
|---|---|
| `active` | The account whose login is live, on one line. claudehop replaces the file whenever it changes the live login (`use`, `next`, `save`, `add`, `rename`), so its modification time is when that last happened. |
| `provider` | The provider new sessions run through, while one is on; `<name>.provider` holds its command. |
| `.usage-cache` | The last reading of every account, as `hop usage --json` reports it: `windows`, `limits`, `fetchedAt`, `limitsAt`, `source` (`usage` or `probe`) and `throttledUntil`, keyed by account name. |
| `next` | The logins `hop next` may choose from, one per line. |
| `.run/<name>/.hop-pids/<pid>` | One file per open `hop run` session of that account, holding the process's start time from `/proc`, so a reused pid can be told apart. |
| `.run/<name>/sessions/<pid>.json` | Written by Claude Code, not claudehop: the session id of each conversation open in that account's `hop run` session. |
| `.lock` | While a command holds claudehop's lock (2.0.0 and later), its pid, start time and command, separated by spaces. |

Each `<name>.json` is a saved login with its tokens. A tool that only wants the email and plan can
read those two keys, but must never copy the tokens anywhere: a refresh token is single-use, and a
second copy that gets renewed signs the account out. To read usage fresh, run `hop usage --json`
rather than calling the endpoint with a saved token yourself, so the renewal rules above still
apply.

[Claude Usage Widget & Token Tracker](https://github.com/StaticB1/claude_ai_usage_widget) is one tool
that does this. It uses the `active` file's modification time, and the session ids under `.run`, to
file each Claude Code turn under the account that made it.

## Things that catch people out

- `/login` opens your default browser, which is already signed in as somebody. Paste the URL into a
  private window to log in as a different account.
- `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` in the environment override the saved login
  entirely. `whoami` and `doctor` warn when either is set.
- `--long` showing `expired (auto-renews)` under `TOKEN` is normal, and so is `stale (renews)` from
  `list --verify`. The access token is short-lived and Claude Code renews it from the refresh token.
  What matters is the refresh token's 30-day window, which is why the default listing shows neither.
- Each account still has its own rate limits and its own terms. This moves your own logins between
  your own terminals; it is not a way to pool quota.
