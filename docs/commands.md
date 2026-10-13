# Command reference

Everything `hop` does, in the order you meet it: adding accounts, switching, one account per
terminal, usage, choosing the login with room, providers, keeping logins healthy, and scripting.
The short version is in the [README](https://github.com/psychofict/claudehop#readme); how and why
it works is in [how it works](how-it-works.md).

## Adding an account

```bash
hop add work         # log in as a new account and save it under that name
hop save home        # save whatever is logged in right now
```

Quit your other `claude` sessions before `add`. It stops and tells you if you haven't, because a
session left running can write its own token back into the credential store mid-login, and you
would end up with the wrong account saved under that name.

Don't `/logout` first. `add` clears the local login itself, and a `/logout` may also revoke the
refresh token of the account you are leaving on Anthropic's side (claude-swap's documentation
reports this; it has not been tested here).

`add` then starts `claude` with no login so you can `/login`, and saves whatever that produces when
you leave with `/exit`. **Paste the login URL into a private browser window.** Your normal browser is
already signed in as one of your other accounts and will authorise that one without asking.

If the login produces nothing (you changed your mind, you pressed Ctrl-C), your previous
credentials come back. If it does produce a login, that login is saved even if the terminal dies on
the way out. A name that would hide a command (`list`) or a provider is refused.

## Switching

```bash
hop                  # a menu of your accounts; answer with a number or a name
hop work             # straight to that account (`hop use work` is the long spelling)
hop list             # the accounts, without the menu; --long adds token expiry and save dates
hop whoami           # who is logged in right now, asked of the API
hop active           # the active account's name, with no network call
```

A hop writes the live login back to its own saved copy first, then puts the other account's in its
place. If the live login matches no saved account (you ran `/login` by hand), it is saved under a
name taken from its email before anything is replaced, so no login is ever dropped. If the account
you hop to has an expired access token, it is renewed first, so the login works the moment it lands.
`--no-sync` skips the write-back.

The swap happens while holding the two lock directories Claude Code takes for its own token
refresh, so the two never overlap. If Claude Code is in the middle of a refresh, `hop` waits up to 9
seconds and then stops with nothing changed.

Every `claude` that is already running follows a hop on its next message, mid-conversation
included, and `hop` lists the sessions it finds when you hop. To keep one terminal on its own
account, use `hop run`.

Once `hop usage` has read your accounts, the menu shows each one's last 5-hour reading. It reads that
from the saved readings and never calls the API, so the menu comes up at once.

## One account per terminal

```bash
hop run work              # claude as the work account, in this terminal only
hop run home -- --resume  # everything after the name goes to claude
```

`hop run <name>` starts `claude` as that account and leaves the live login alone. Your other
terminals keep their account, and a `hop` somewhere else does not move this one.

Each account gets a config home of its own, `accounts/.run/<name>/`, and `claude` is pointed at it
with `CLAUDE_CONFIG_DIR`. The home holds the account's login and a copy of your global config without
the signed-in account. Your settings, `CLAUDE.md`, skills, agents, commands, hooks, plugins, output
styles, keybindings, plans, prompt history and `projects` are links to the real ones. A run session
therefore looks like your normal one, and conversations and memory are shared across accounts.
`CLAUDE_HOP_SHARE=notes.md,other` links more names. Things you change inside a session in the copied
config, such as a new MCP server or a trust prompt, stay in its home, and MCP logins belong to the
account.

The login in that home is the one Claude Code renews, so `hop run` saves it back to the saved copy
when the session ends, and `doctor --fix` does the same after a crash. While a session is open,
`use`, `renew`, `usage`, `rm` and `rename` leave its account alone, because two copies of one login
would rotate separately and one would be signed out. Running the live account is plain `claude`,
with no second home. If you `/login` as someone else inside a session, that login is saved under its
own name and the account you ran is unchanged.

Linux only for now. On macOS Claude Code keeps its login in the keychain, and a second login under
another config dir is not handled yet ([issue 1](https://github.com/psychofict/claudehop/issues/1)).

## Usage

```
$ hop usage
   NAME  5 HOURS             7 DAYS                  NOTE
   home  0%  reset, was 98%  61%  resets 4d22h
   side  71%  resets 3h01m   29% Fable  resets 6d0h  read through claude
*  work  42%  resets 2h13m   18%  resets 3d3h
```

`hop usage` shows how much of each account's 5-hour and 7-day allowance is spent, and when each
window resets. It reads them from the endpoint behind Claude Code's own `/usage`. That endpoint
limits clients other than Claude Code, and a throttled token can stay blocked for half an hour to an
hour. So `hop usage` asks only when you run it and keeps the last good reading in
`accounts/.usage-cache` (percentages and times, no tokens). It does not ask again within a minute,
or before the server's `Retry-After` has passed. A throttled row shows the last reading and its age.
Nothing polls in the background.

Three things keep a reading possible for every account, not only the one you are on:

- **Idle logins are renewed first.** An idle account's access token expires 8 hours after it was
  last renewed, and the endpoint will not take it. `hop usage` renews it first, as `hop renew` would.
  It never renews the live login or an account open in a `hop run` session, because the Claude Code
  that holds them renews them itself.
- **A reset window reads as reset.** A window whose reset time has passed is empty again, shown as
  `0%  reset, was 98%`, without anyone being asked.
- **`--probe` reads through Claude Code.** When the endpoint will not answer, `--probe` runs one
  `claude -p` with the smallest model, as that account. It runs in a throwaway config home with no
  tools, MCP servers or settings, and reads the rate-limit figures Claude Code reports with every
  reply. It takes about three seconds and spends a sliver of the account's allowance. On an account
  whose 5-hour window has not started, that one request starts it, so it only happens when you ask.
  Such a row says "read through claude".

Team and Enterprise seats report no all-model 7-day window. Their weekly limits, when they have any,
come as separate meters, often for one model. The 7-day column then shows the fullest one with its
model (`29% Fable`), and `--json` carries every meter under `limits`.

`hop usage <name>` reads one account. `--no-cache` (or `--fresh`) asks again even within the minute,
though still never before a `Retry-After`. `--json` is for scripts; see [Scripting](#scripting).

## Hop to the login with room

```bash
hop next home work side   # once: the logins it may choose from
hop next                  # from then on
```

```
`claudehop next` now chooses among home, work, side
  home  5h 12%, resets 4h39m
  side  5h 88%, resets 1h04m
switched to home (me@gmail.com, team)
```

`hop next` reads the 5-hour window of every login in its list except the one you are on, and hops to
the one with the most room. Within ten points it prefers the window that resets soonest, because what
that one has left is lost at the reset. A login at 95% or more of its 5-hour window, or at an
all-model weekly limit, is skipped. A reading the endpoint will not give is taken through Claude Code,
as `--probe` does, so the choice is never made on an old figure. When no login has room it stays where
it is, exits with status 1, and says which one frees up first.

The list is kept in `accounts/next`, one name per line, so a login you keep for other work is never
picked by accident. Give `hop next` new names to replace it. It is a command you run; nothing hops on
its own.

## Providers: Bedrock, Vertex, a gateway

Some ways of running Claude Code are not a login at all: Amazon Bedrock and Vertex read environment
variables, and a gateway is a base URL. Write a small launcher script that sets them and runs
`claude "$@"`, register it once, and hop to it like an account:

```bash
hop provider bedrock claude-bedrock   # name, then the command to run instead of `claude`
hop bedrock                           # new `claude` commands go through the launcher
hop off                               # back to your saved login
```

Hopping to an account (`hop work`) also switches a provider off. Saved logins are never touched, so a
provider works even when a login has expired. `hop` lists providers under your accounts, `hop active`
prints the provider's name while one is on (`hop active --json` keeps the account too), and
`hop doctor` reports a launcher that has gone missing.

The switch is read by a `claude` function in the shell glue, so it applies to terminals that have
loaded it (`source ~/.claude/claudehop.sh`, or open a new one). Sessions that are already running keep
what they started with. The command must be a single word; put arguments in the launcher.

## Keeping logins healthy

```bash
hop doctor           # check the setup and plan the next re-login; --fix repairs what it can
hop renew            # refresh the saved tokens; one name, or all of them
hop list --verify    # check every saved token against the API
hop rm <name>        # delete a saved account (does not log you out)
hop rename <old> <new>
```

Every login needs a real `/login` about once a month: a refresh token dies 30 days after the login
that issued it, and renewing does not move that date. `hop doctor` names the day the earliest
account comes due and suggests logging them all in on that day, so they share one date from then on.
It also warns 14 days before any one account's window closes. [How it works](how-it-works.md#every-account-needs-a-real-login-about-once-a-month)
has the measurements.

`doctor` checks for these, and `--fix` repairs the ones marked:

- folder and file permissions looser than `700` and `600` (fixed);
- a profile that will not parse, or has no saved login;
- a saved copy that has fallen behind the live login or a finished `hop run` session (fixed);
- stale backup files that hold an old credential (fixed);
- lock directories left by a run that died (fixed);
- a provider whose launcher is missing, or a provider switch that names nothing (fixed);
- `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` set, which overrides the saved login.

Its output contains no secrets, so it is safe to paste into an issue.

`hop renew` refreshes saved tokens in place. It keeps idle profiles usable and shows you a dead one
before you need it, but it buys no extra days. It leaves the live login alone while `claude` sessions
are running, and any account open in a `hop run` session, unless you pass `--yes`.

`hop list --verify` asks the API about each saved token and shows its state. A token that has simply
expired reads `stale (renews)`, because Claude Code renews it on the next start. Answers are kept for
60 seconds in `accounts/.verify-cache` (email, plan, token state, no tokens), and only for the same
login, so a re-login inside the minute is asked about again. `--no-cache` asks again regardless.

Two ready-made helpers are in `extras/`:

- **A daily check.** `claudehop-watch` renews the saved logins and puts up a desktop notification a
  week before the earliest login window closes. Install it as a systemd user timer:

  ```bash
  cp extras/claudehop-watch.{service,timer} ~/.config/systemd/user/
  cp extras/claudehop-watch.py ~/.claude/bin/claudehop-watch
  systemctl --user enable --now claudehop-watch.timer
  ```

  `CLAUDEHOP_WARN_DAYS` sets the notice (7 days), and `CLAUDEHOP` the path to `claudehop` when the
  service cannot find it on its own `PATH`.
- **A statusline snippet.** `extras/statusline-snippet.sh` adds the active account's name to Claude
  Code's statusline, and a countdown in the last week before a re-login is due. It reads two small
  files and never calls the API, because the statusline runs constantly.

## Scripting

`--json` on `list`, `whoami`, `active`, `usage` and `doctor` prints machine-readable output with no
secrets in it. `hop usage --json` gives, for each account:

| Field | Meaning |
|---|---|
| `name`, `active` | the account, and whether it is the live login |
| `windows` | `five_hour`, `seven_day` and any per-model window, each `{pct, resetsAt}`, as the server last reported them |
| `limits` | the weekly meters Team seats report: `{kind, group, pct, resetsAt, scope}` |
| `fetchedAt`, `limitsAt` | when the windows and the meters were read (Unix seconds) |
| `source` | `usage` for the endpoint, `probe` for a reading taken through Claude Code |
| `throttledUntil` | when the endpoint may be asked again, if it refused |
| `note` | why a reading is old or missing |

A window in `windows` keeps the figure the server sent even after its reset time has passed; compare
`resetsAt` with the clock, as the table does.

The exit status is 0 when the command did what it was asked, and 2 for a command it does not
understand. It is 1 when the command could not do it: a renewal that failed, `hop next` with no
login that has room, `hop active` with nothing active, or `hop doctor` with an error it could not
fix. Older scripts can keep using `use`, `switch`, `ls`, `sync` (write the live login back to
its saved copy) and the pre-1.2.0 names `claude-acct` and `cacct`.

Settings, all optional:

| Variable | What it does |
|---|---|
| `CLAUDE_CONFIG_DIR` | Claude Code's config folder, `~/.claude` by default |
| `CLAUDE_ACCOUNTS_DIR` | where the saved logins live, `<config>/accounts` by default |
| `CLAUDE_HOP_BACKEND` | `auto`, `file` or `keychain`: where the live login is kept |
| `CLAUDE_HOP_OFFLINE` | `1` makes no network call at all |
| `CLAUDE_HOP_TIMEOUT` | seconds to wait for each API call (10) |
| `CLAUDE_HOP_LOCK_WAIT` | seconds to wait for Claude Code's refresh lock (9) |
| `CLAUDE_HOP_SHARE` | more names to link into a `hop run` home, comma-separated |
| `CLAUDE_HOP_PROBE_MODEL` | the model `--probe` uses (`haiku`) |
| `CLAUDE_HOP_PROBE_TIMEOUT` | seconds to wait for a probe (60) |
| `NO_COLOR` | plain output, like `--no-color` |

The `CLAUDE_ACCT_*` names from before 1.2.0 still work wherever the `CLAUDE_HOP_*` ones do.
