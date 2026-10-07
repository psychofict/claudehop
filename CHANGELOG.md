# Changelog

All notable changes to this project are documented here.
This project follows [semantic versioning](https://semver.org/).

## [1.7.2] — 2026-10-07

### Changed

- **Releases publish to PyPI with a trusted publisher.** The release workflow used a stored
  PyPI token. PyPI now trusts this repository, the release workflow and the `pypi` environment
  directly, so the job proves who it is for each run and no token is kept anywhere. The tool
  itself is unchanged.

## [1.7.1] — 2026-10-07

### Changed

- **The README is half its length and leads with evidence.** It now opens with the two
  commands that cover the tool, then a table of measured differences from claude-swap and
  clauth (size, packages, start-up time, features), including the rows where they are ahead.
  The method and every number are on a new comparison page. The reference material that
  was in the README moved, with its text kept, to `docs/commands.md` and
  `docs/how-it-works.md`.
- **Package metadata.** A new summary, more keywords (Max, Pro, Team, Bedrock, Vertex),
  links to the docs, the comparison, Discussions and the security policy, and the licence
  in the current standard form (the old table form was deprecated). The sdist now carries
  the docs.

### Added

- A code of conduct, a pull request template, a feature request form, a support page,
  code owners, and Dependabot for the pinned GitHub Actions.
- A weekly and per-push CodeQL scan of the Python.

## [1.7.0] — 2026-10-06

### Added

- **`hop run <name> [claude arguments]`** starts `claude` as one account in the
  terminal you are in and leaves the live login alone, so two terminals can be on
  two accounts at once. A global hop cannot do that, because Claude Code reads
  its login again before every message. Each account gets a config home of its
  own in `accounts/.run/<name>/`, which `claude` is pointed at with
  `CLAUDE_CONFIG_DIR`. It holds the account's login and a copy of the global
  config without the signed-in account. Settings, `CLAUDE.md`, skills, agents,
  commands, hooks, plugins, output styles, keybindings, plans, prompt history and
  `projects` are links to the real ones, so a run session looks like your normal
  one and conversations are shared across accounts (`CLAUDE_HOP_SHARE` adds more
  names). The session's renewed login is saved back to the profile when it ends,
  by `doctor --fix` after a crash, and at the next launch. `use`, `renew`, `rm`
  and `rename` leave an account alone while a session has it open. Running the
  live account is plain `claude`. A `/login` as another account inside a session
  is saved under its own name. Linux only for now. Checked with Claude Code
  2.1.284: three sessions at once sent three different logins, and the live
  login and active pointer did not move.

## [1.6.0] — 2026-10-06

### Fixed

- **A switch no longer races Claude Code's token refresh.** While Claude Code
  refreshes, it holds two lock directories, reads the login, calls the token
  endpoint and writes the result back. A switch inside that window was
  overwritten by the old account's refreshed token, and the profile we had just
  saved held a refresh token the server had retired. `use`, `add` and `renew`
  now hold the same two locks, in Claude Code's order, while they read and
  replace the live login; if they stay busy for 9 seconds (`CLAUDE_HOP_LOCK_WAIT`)
  the command stops with nothing changed. Behaviour checked on Claude Code
  2.1.284 by tracing it in a sandbox. `doctor` reports and `--fix` removes a lock
  left behind by a run that died.
- **Hopping to the account you are already on no longer swaps in a spent token.**
  Once Claude Code has rotated the live token, the saved copy is older than the
  live one. `hop <current account>` loaded the saved block, wrote the live block
  into the same profile, then put the saved (older) block back as the login, so
  the live store held a refresh token that had already been used. Every further
  run flipped the two again. It now keeps the live login and brings the saved
  copy up to date.
- **`add`, `save` and `rename` refuse names that would hide something.** An
  account called `list` could never be reached as `hop list`, and one named after
  a provider shadowed it. Accounts that already have such a name keep working.
- **`doctor` reports a profile it cannot parse** and carries on, instead of
  stopping on the first broken file, and the scan for the live account skips it.

### Added

- **`hop usage`** shows each account's 5-hour and 7-day usage and when each
  window resets, from the endpoint behind Claude Code's `/usage`. That endpoint
  throttles clients other than Claude Code, so the command asks only when run,
  keeps the last good reading in `accounts/.usage-cache` (no tokens), and waits
  out the server's `Retry-After` before asking again. Throttled, rejected or
  aged-out accounts show their last reading with its age. `--json` for scripts.
- **Providers.** `hop provider <name> <command>` registers a way of running Claude
  Code that is not a saved login (Amazon Bedrock, Vertex, a gateway), and
  `hop <name>` switches new sessions to it. `hop off`, or hopping to any account,
  switches back. A provider never touches the saved logins. The `claude`
  function in the shell glue (and in `hop shell-init`) reads the switch, so only
  new commands in shells that have loaded it are affected. `list`, the picker,
  `active`, `rm` and `doctor` all know about providers, and `--json` output gains
  `provider` and `providers` keys. While a provider is on, `hop active` prints its
  name instead of the account name.

### Changed

- **The docs and the note after a hop no longer say open sessions keep their
  account.** They do not. Claude Code reads the credential store again before
  each message: with a fake endpoint, a session sent its first message with the
  old login and, two seconds after the file was swapped, its second message with
  the new one (Linux, Claude Code 2.1.284, headless mode). A hop therefore moves
  every open `claude` on its next message, a conversation in progress included,
  and one `hop` cannot give two terminals two accounts. The README headline
  promised that, and now says what it does. macOS reads from the keychain, which
  claude-swap's documentation says is cached for about half a minute; that is
  not tested here.

## [1.5.0] — 2026-08-31

### Fixed

- **The active account is judged by the live login, not by its saved copy.**
  A profile on disk is a snapshot from the last hop or sync. Claude Code rotates
  the live token behind it every few hours, and a browser re-login replaces it
  outright, so for whichever account is active the credential store is newer by
  definition. `list` and `doctor` were reading the snapshot, which meant a
  working login could be reported as `expired (auto-renews)` with a dead refresh
  window while the account was in fact fine. Both now read the store for the
  active account, and `doctor` reports a snapshot that has fallen behind as its
  own warning, with `--fix` to sync it.

### Added

- **`hop renew [name]`** refreshes the saved tokens in place, all of them or one.
  It rotates the refresh token against the same endpoint Claude Code uses and
  writes the result back immediately, which matters because the old token dies
  the moment the reply arrives. It skips the live login while other `claude`
  sessions are running, since those are holding the token it would rotate away;
  `--yes` overrides. It does not extend anything, and says so.
- **Hopping to an account with an aged-out access token renews it first.**
  Claude Code would have renewed it on the next start anyway, but only if
  nothing rewrote the store in between, and until then `whoami` and the
  statusline report a dead token for an account that is fine.
- **`extras/claudehop-watch.py`** with a systemd user service and timer: renews
  the saved tokens daily and raises a desktop notification before the earliest
  refresh window closes. The statusline snippet in `extras/` now counts down the
  last week to the next real login.

### Changed

- The note on expiry now carries a second measurement, taken 2026-08-31 by
  refreshing a saved token by hand. Refreshing rotates the refresh token, which
  makes it easy to assume the window rotates too, but the reply came back with
  `refresh_token_expires_in` landing on the same wall-clock minute the old token
  was already going to expire. Access tokens are a flat 8 hours, and a fresh
  login can hand back less than 30 days: one account got 27.5.

## [1.4.0] — 2026-08-11

### Added

- **On PyPI** as `claudehop-cli` — the bare name is held too close to an
  unrelated project for PyPI to allow it; the commands are unchanged and still
  `hop` and `claudehop`:

  ```bash
  pipx install claudehop-cli
  ```

  Still no dependencies, still one file you can read in a sitting. `install.sh`
  is unchanged and remains the way to get the shell glue with it.
- **Tagged releases build and publish themselves.** `.github/workflows/release.yml`
  checks the tag against `VERSION`, builds the wheel and the sdist, publishes to
  PyPI with trusted publishing (no API token anywhere), and attaches both files
  to the GitHub release.
- **`claudehop shell-init`** prints the shell glue a packaged install needs —
  the `hop` alias and tab-completion, without the PATH line the repo installer
  writes. `eval "$(claudehop shell-init)"` in your rc file.

### Changed

- The tool moved from `bin/claudehop` to `claudehop.py` at the top of the repo,
  so it can be both the installed script and the packaged module. `install.sh`,
  `~/.claude/bin/claudehop` and every command name are unaffected.
- Tab-completion now offers `shell-init` and `version`, and the completion list
  is generated from the command table — a test fails if the sourced glue and the
  packaged one drift apart.

## [1.3.0] — 2026-08-06

### Added

- **`doctor` now works out when you next have to log in for real, and the
  cheapest day to do it.** A refresh token lasts about 30 days from the `/login`
  that issued it and using the account does not extend it — measured across four
  accounts, one of which had its access token reissued that morning and still
  expired 30 days after its first login. So it is a hard monthly expiry per
  account, and with several accounts the dates drift apart into a browser
  round-trip per account per month. Logging in early resets the full window, so
  `doctor` names the account that goes first and says to do them all that day,
  which collapses them onto one date:

  ```
  re-login     by 2026-08-30 (work); the other 3 by 2026-09-04
               windows are ~30d from login and do not slide, so re-login all 4 on
               2026-08-30 and they collapse to one date
  ```

  `doctor --json` carries the same thing under `reloginPlan`, and an account whose
  refresh token has already died is called out separately — that one needs
  `claudehop add` rather than planning.

### Changed

- **The expiry warning starts 14 days out instead of 7.** With several accounts on
  staggered dates, one week is not enough notice to plan a single sitting.

## [1.2.1] — 2026-08-06

### Changed

- **`hop` on its own now asks which account you want.** It prints the list
  numbered and switches to the one you pick; Enter leaves you where you are. You
  no longer have to read a table and then retype a name out of it. Piped output,
  `--json` and a single saved account all still get the plain listing, so
  statuslines and scripts are unaffected.
- **The default listing is name, email and plan.** Token expiry and save dates
  moved behind `--long`. `expired (auto-renews)` under `TOKEN` needed a paragraph
  of README to be readable and was the most-misread thing the tool printed; it is
  not something you need in order to choose an account.
- **`add` stops if other `claude` sessions are running** instead of warning and
  carrying on into a corrupted result. `--yes` overrides it.
- **`add` tells you to use a private browser window** before it hands you to
  `/login`, rather than leaving it in the README's gotchas.
- `help` leads with the three commands you actually use and lists the rest below.

### Fixed

- **`add` could lose a login it had already completed.** The new credential was
  read inside the cleanup path but written to disk after it, with an API call for
  the account's email in between. Anything that ended the process in that window
  — Ctrl-C, closing the terminal, the identity lookup being cut short — left you
  logged in as an account with no profile saved for it. The token is now written
  first and the email filled in afterwards, so an interrupted `add` still leaves
  a usable profile. Recover one from an older version with `claudehop save <name>`
  while that login is still live.
- **`add` no longer unwinds on the first Ctrl-C.** In Claude Code, Ctrl-C cancels
  the current turn rather than quitting, so `add` used to start cleaning up while
  `claude` was still running and still writing to the credential store. It now
  ignores SIGINT while the child runs, the way a shell does, and lets `claude`
  decide when to exit. SIGHUP and SIGTERM are turned into a clean unwind instead
  of killing the process outright.
- **`add` no longer files one account's credential under another account's
  name.** A `claude` session that was already running writes its own refreshed
  token into the credential store, and `add` would save that as the new account.
  It now checks the account UUID before keeping the profile, and puts a refreshed
  token back where it belongs instead.
- **Replacing an existing account no longer keeps the old email and plan** next
  to the new account's token.

## [1.2.0] — 2026-08-05

### Changed

- **Renamed to `claudehop`.** The command is `claudehop`, with `hop` as a shell
  alias. `claude-acct` and `cacct` keep working as shell functions, so nothing
  you have typed before breaks.
- Environment variables are now `CLAUDE_HOP_BACKEND`, `CLAUDE_HOP_OFFLINE` and
  `CLAUDE_HOP_TIMEOUT`. The old `CLAUDE_ACCT_*` names are still honoured.
  `CLAUDE_CONFIG_DIR` and `CLAUDE_ACCOUNTS_DIR` are unchanged.

Your saved accounts do not move: they stay in `~/.claude/accounts/`, and
`install.sh` removes the old `claude-acct` binary and glue so you never end up
with two copies on your PATH.

## [1.1.0] — 2026-08-05

First public release, under the name `claude-acct`.

### Added

- **macOS keychain backend.** Reads and writes the `Claude Code-credentials`
  item the same way Claude Code does, and falls back to `.credentials.json`
  when the keychain holds no login. Override with `CLAUDE_ACCT_BACKEND`.
- **`doctor`** — checks permissions, stale files, dangling pointers, expiring
  refresh tokens, environment overrides and running sessions. `--fix` repairs
  what it safely can.
- **`active`** — prints just the active account name with no network call, for
  statuslines and scripts.
- **`--json`** on `list`, `whoami`, `active` and `doctor`. No secrets in it.
- **A lock** (`accounts/.lock`) around every mutating command, so two switches
  at once can't interleave and lose an account.
- Warning when an account's *refresh* token is within a week of expiring —
  that's the one whose death means a real re-login.
- `--version`, `--no-color`, `NO_COLOR` and `CLICOLOR_FORCE` support.
- zsh tab-completion (via `bashcompinit`), and `--no-rc` for `install.sh`.

### Fixed

- **`add` could leave you logged out of everything.** If `claude` was missing,
  exited without a login, or you hit Ctrl-C, the credentials it had cleared were
  never put back. They are now restored in a `finally` block.
- **Crash on macOS.** The running-session check read `/proc` unconditionally;
  it now falls back to `pgrep` and never raises.
- **Misaligned table.** Colour escapes inside a cell were counted as visible
  width, so one expired token knocked every later column out of line.
- **`list --verify` reported healthy accounts as `invalid`.** An access token
  that has simply aged out now reads `stale (renews)`, which is what actually
  happens to it.
- `rename` leaked a file descriptor and could leave the active pointer behind.
- `rm` left the active pointer naming a deleted account.
- Unknown options (`--typo`) were silently treated as an account name; they now
  exit 2 with a usage error.
- Account names are validated, so a name can't escape the accounts directory,
  and an auto-generated name can no longer shadow a command.
- `list --verify` only rewrites a profile when something actually changed.
- `claude-acct list | head` no longer prints a `BrokenPipeError` traceback.

### Changed

- `list` no longer calls the API on the default path — the bare command is now
  local-only and instant. `--verify` still asks, and now asks for every account
  in parallel.
- Profile writes no longer leave `<name>.json.bak` files lying around; they were
  extra copies of a live credential. `doctor --fix` removes old ones.
- The `STATE` column only appears with `--verify`, where it means something.
- `whoami` exits 1 when nothing is logged in.
