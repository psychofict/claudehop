# Changelog

All notable changes to this project are documented here.
This project follows [semantic versioning](https://semver.org/).

## [1.1.0] — 2026-08-05

First public release.

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
