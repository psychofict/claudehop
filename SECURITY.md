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
- The only network call is `GET https://api.anthropic.com/api/oauth/profile`
  with the account's own bearer token, to resolve an email and plan.
  `CLAUDE_HOP_OFFLINE=1` disables it.

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
