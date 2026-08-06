# Changelog

All notable changes to this project are documented here.
This project follows [semantic versioning](https://semver.org/).

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
