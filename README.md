# claude-acct

Switch Claude Code between several Claude accounts without logging in again.

```
$ claude-acct
   NAME     EMAIL                  PLAN  TOKEN    STATE  SAVED
   eben     ebstarmusic@gmail.com  max   5h left  ok     2026-08-03
*  gractor  eben@gractor.com       team  7h left  ok     2026-08-03

$ claude-acct eben
switched to eben (ebstarmusic@gmail.com, max)
```

Personal Max account in one terminal, work Team seat in another — two separate
usage pools, one machine, no browser round-trip to move between them.

## Install

```bash
git clone <this repo> && cd claude-acct
./install.sh          # symlinks into ~/.claude, adds one line to your rc file
```

`./install.sh --copy` installs copies instead of symlinks, `--uninstall` reverses
it. Neither ever touches `~/.claude/accounts/`, where the credentials live.

Then open a new terminal.

## Use

```bash
claude-acct                  # list saved accounts, * marks the active one
claude-acct add work         # log in as a new account and save it
claude-acct use work         # switch — or just: claude-acct work
claude-acct whoami           # who am I right now (asks the API)
claude-acct list --verify    # check every saved token against the API
claude-acct save <name>      # save the current login under a name
claude-acct sync             # push the live login back into its saved file
claude-acct rm <name>        # delete a saved account (does not log you out)
claude-acct rename <a> <b>
```

Adding an account runs `claude` for you so you can `/login`; on exit it saves
whatever credentials that produced. If you already logged in by hand, just
`claude-acct save <name>`.

## How it works

Claude Code keeps the live login in the `claudeAiOauth` key of
`~/.claude/.credentials.json`. This tool keeps one saved copy of that block per
account in `~/.claude/accounts/<name>.json` and swaps the active one in and out.
The `mcpOAuth` key in the same file — your Vercel/Neon/etc. MCP logins — is left
alone, so switching accounts doesn't sign you out of anything else.

Nothing else needs patching. Account identity in `~/.claude.json` (`oauthAccount`)
is re-fetched from the API by Claude Code at startup: put a bogus email in there,
start a session, and it comes back corrected. So swapping the credential is the
whole job.

Identity, plan and token checks come from `GET /api/oauth/profile` with the
account's own bearer token. Set `CLAUDE_ACCT_OFFLINE=1` to skip every API call.

### Two details that make or break it

**Access tokens rotate.** Claude Code refreshes them every few hours and writes
the new one straight into the credentials file. A switcher that identifies the
active profile by comparing token values therefore stops recognising it after the
first refresh — and then loses the refreshed token when you switch away. So the
active profile is tracked in `accounts/active` and confirmed against the account
UUID from the API, and every switch writes the live block back to its profile
before loading the next one.

**A login you can't identify is stashed, never dropped.** If the live credentials
match no saved profile (you ran `/login` by hand, say), switching saves them under
a name derived from the account's email first. You can always get back to a
session you'd otherwise have to re-authenticate.

## Gotchas

- Switching affects **new** `claude` processes. Sessions already running keep the
  account they started with, and will rewrite the credentials file when their
  token refreshes — which can silently undo a switch. `claude-acct` prints the
  PIDs it finds; quit them for a clean switch.
- `/login` opens your default browser, which is already signed in as somebody.
  Paste the URL into an incognito window to authenticate as a different account.
- `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` in the environment override
  the saved login entirely. `claude-acct whoami` warns when either is set.
- Linux/macOS. On macOS Claude Code may keep credentials in the Keychain rather
  than in `.credentials.json`; this reads and writes the file only.

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

## Files

```
bin/claude-acct              the tool (python3, stdlib only)
shell/claude-acct.sh         PATH, tab-completion, back-compat aliases
extras/statusline-snippet.sh show the active account in the Claude Code statusline
install.sh                   symlink/copy into ~/.claude, wire up the rc file
test/test-switch.sh          18 checks against a throwaway config dir, no network
```

## Tests

```bash
./test/test-switch.sh
```

Runs entirely inside a temp dir with fake credentials — it never reads or writes
a real account. Covers the swap, mcpOAuth preservation, token rotation, the stash
path, the housekeeping commands and file permissions.

## Licence

MIT.
