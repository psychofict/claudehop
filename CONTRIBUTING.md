# Contributing

Thanks for looking. This is a small tool and it intends to stay small.

## The rules that keep it small

1. **Python 3.9+, standard library only.** No dependencies, no build step, no
   package registry. `bin/claude-acct` must stay a single file you can read in
   one sitting and run straight from a clone.
2. **Never lose a login.** Any code path that replaces the live credential must
   first write what was there into a profile. If you can't identify it, stash it
   under a generated name. Losing a token costs a browser round-trip and,
   sometimes, a device-approval email.
3. **Tests use fake credentials and no network.** `test/test-switch.sh` runs
   against a temp `CLAUDE_CONFIG_DIR` with `CLAUDE_ACCT_OFFLINE=1`. A test that
   needs a real account is not a test we can run.
4. **Secrets never get printed.** Not in `--json`, not in errors, not in debug
   output.

## Working on it

```bash
git clone https://github.com/psychofict/claude-acct.git
cd claude-acct
./install.sh              # symlinks, so your edits are live immediately
./test/test-switch.sh     # 55 checks, about two seconds
```

Before opening a pull request:

```bash
./test/test-switch.sh
ruff check bin/claude-acct        # if you have it; CI runs it either way
shellcheck install.sh shell/*.sh test/*.sh
```

Add a check to `test/test-switch.sh` for anything you fix or add. If the
behaviour is user-visible, update `README.md` and `CHANGELOG.md` in the same
pull request.

## Things worth doing

- Verification of the macOS keychain backend against a real Mac. It is written
  against Claude Code's own `security` calls and tested through a stand-in, but
  nobody has run it on real hardware yet.
- fish shell completion (`shell/claude-acct.sh` is POSIX/bash + zsh today).
- A `--verify` cache so `list --verify` doesn't re-ask the API every time.

## Style

Match what's there: plain names, comments that explain *why*, error messages
that tell the user what to do next. Keep line length near 100.
