# Security

## What this tool holds

`~/.claude/accounts/<name>.json` contains a full, live Claude OAuth credential:
an access token and a refresh token. Anyone who can read those files can act as
you in Claude Code until the refresh token expires. Treat them exactly like an
SSH private key.

What the tool does about that:

- `accounts/` is created `700`, every profile is written `600`, and both are
  re-tightened on every run if something loosened them.
- Writes are atomic — a new file with the right mode, `fsync`, then `rename` —
  so a crash mid-write cannot leave a half-written or world-readable credential.
- No `.bak` copies of profiles are kept. `claudehop doctor --fix` removes any
  left by an older version.
- Tokens never appear in `--json` output, in log lines, or in any error message.
- Network calls go only to Anthropic, each with the account's own token:
  `GET https://api.anthropic.com/api/oauth/profile` (email and plan),
  `GET https://api.anthropic.com/api/oauth/usage` (`hop usage`), and
  `POST https://platform.claude.com/v1/oauth/token` (renewing a token, from
  `renew` or a hop to an account whose access token has aged out).
  Requests say they come from claudehop; the tool does not pose as Claude Code.
  `CLAUDE_HOP_OFFLINE=1` disables all of them.
- `accounts/.usage-cache` and `accounts/.verify-cache` hold usage and verification
  metadata (times, percentages, email, plan, token state), never a token.
- `hop run` keeps a copy of an account's login in `accounts/.run/<name>/` (folder `700`,
  login `600`). `rm` deletes it, unlinking and never following the links that point at your
  own settings and projects.
- While it replaces the live login, the tool briefly holds the lock directories
  Claude Code uses for its own token refresh (`<config dir>/.oauth_refresh.lock`
  and `<config dir>.lock`). `doctor` reports one that a crashed run left behind.

## Known limits

- **`.credentials.json.bak`.** When the file backend replaces the live
  credentials it keeps one backup, mode `600`, so a corrupted write is
  recoverable. It contains the previous account's token.
- **macOS keychain.** Writing goes through `/usr/bin/security
  add-generic-password -X <hex>`, so the secret is in that process's argv while
  it runs and is visible to `ps` on the same machine. Claude Code itself writes
  the item exactly the same way; there is no stdin interface to `security`.
- **Root and same-user processes.** Anything running as your user can read the
  files. This tool does not and cannot defend against that.
- **`git`.** `accounts/`, `*.bak` and `*.credentials.json` are in `.gitignore`.
  Do not move a profile into a repository.

## Reporting a vulnerability

Open a [security advisory](https://github.com/psychofict/claudehop/security/advisories/new)
on the repository. Please don't file a public issue for anything that could
expose credentials. Expect a first reply within a week.
