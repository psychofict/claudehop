# Command reference

Everything `hop` does, in the order you meet it. The short version is in the
[README](https://github.com/psychofict/claudehop#readme).

## Adding an account

```bash
hop add work
```

Quit your other `claude` sessions first. `add` will stop and tell you if you
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

If the login produces nothing (you changed your mind, you hit Ctrl-C), your
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
hop next             # hop to the login with the most 5-hour room left
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

## One account per terminal

```bash
hop run work              # claude as the work account, in this terminal only
hop run home -- --resume  # everything after the name goes to claude
```

`hop run <name>` starts `claude` as that account and leaves the live login
alone. Your other terminals keep their account, and a `hop` somewhere else does
not move this one.

Each account gets a config home of its own, `accounts/.run/<name>/`, and
`claude` is pointed at it with `CLAUDE_CONFIG_DIR`. The home holds the account's
login and a copy of your global config without the signed-in account. Your
settings, `CLAUDE.md`, skills, agents, commands, hooks, plugins, output styles,
keybindings, plans, prompt history and `projects` are links to the real ones, so
a run session looks like your normal one, and conversations and memory are shared
across accounts. `CLAUDE_HOP_SHARE=notes.md,other` links more names. Things you
change inside a session in the copied config (a new MCP server, a trust prompt)
stay in its home, and MCP logins belong to the account.

The login in that home is the one Claude Code renews, so `hop run` saves it back
to the profile when the session ends, and `doctor --fix` does the same after a
crash. While a session is open, `use`, `renew`, `rm` and `rename` leave its
account alone, because two copies of one login would rotate separately and one
would be signed out. Running the live account is plain `claude`, with no second
home. If you `/login` as someone else inside a session, that login is saved under
its own name and the account you ran is unchanged.

Linux for now. On macOS Claude Code keeps its login in the keychain, and a second
login under another config dir is not handled yet.

## Usage

```
$ hop usage
   NAME   5 HOURS                 7 DAYS               NOTE
   home   0%  reset, was 98%      61%  resets 4d23h
*  work   42%  resets 2h14m       18%  resets 3d4h
   team   71%  resets 3h02m       29% Fable  resets 6d  read through claude
```

How much of each account's 5-hour and 7-day allowance is spent, and when each
window resets, read from the endpoint behind Claude Code's own `/usage`. That
endpoint limits clients other than Claude Code, and a throttled token can stay
blocked for half an hour to an hour (a `Retry-After` of 1524 seconds has been
seen, and up to an hour since). So `hop usage` asks only when you run it,
remembers the last good reading in `accounts/.usage-cache` (percentages and
times, no tokens), and does not ask again until the server's `Retry-After` has
passed. A throttled row shows the last reading and its age. Nothing polls in the
background. `hop usage <name>` checks one account, `--json` is for scripts.

Three things keep a reading possible for every account, not just the one you
are on:

- An idle account's access token ages out 8 hours after it was last renewed,
  and the endpoint will not take it. `hop usage` renews it first, as `hop renew`
  would. It never renews the live login or an account open in a `hop run`
  session, because those are renewed by the Claude Code that holds them.
- A window whose reset time has passed is empty again. It reads `0%  reset,
  was 98%` without anyone being asked.
- `--probe` reads the figures through Claude Code itself when the endpoint will
  not answer. It runs one `claude -p` with the smallest model, as that account,
  in a throwaway config home, with no tools, MCP servers or settings, and reads
  the rate-limit figures Claude Code reports with every reply. It takes about
  three seconds and spends a sliver of the account's allowance, and on an
  account whose 5-hour window has not started, that one request starts it. So
  it only happens when you ask. `CLAUDE_HOP_PROBE_MODEL` picks another model.

Team and Enterprise seats report no all-model 7-day window. Their weekly caps,
when they have any, come as separate meters, often for one model; the 7-day
column then shows the fullest one with its model (`29% Fable`), and `--json`
carries every meter under `limits`.

## Hop to the login with room

```bash
hop next work team side   # once: the logins it may choose from
hop next                  # from then on
```

`hop next` reads the 5-hour window of every login in its list except the one you
are on, and hops to the one with the most room. Within ten points it prefers the
window that resets soonest, because what that one has left is lost at the reset.
A login at 95% or more of its 5-hour window, or at an all-model weekly limit, is
skipped. A reading the endpoint will not give is taken through Claude Code, as
`--probe` does, so the choice is never made on an old figure. When no login has
room it stays where it is and says which one frees up first.

The list is kept in `accounts/next`, one name per line, so a login you keep for
other work is never picked by accident. Give `hop next` new names to replace it.
It is a command you run; nothing hops on its own.
