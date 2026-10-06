# Contributing

Thanks for looking. This is a small tool and it intends to stay small.

## The rules that keep it small

1. **Python 3.9+, standard library only.** No dependencies, no build step.
   `claudehop.py` must stay a single file you can read in one sitting and run
   straight from a clone — `pyproject.toml` packages that one module and
   nothing else.
2. **Never lose a login.** Any code path that replaces the live credential must
   first write what was there into a profile. If you can't identify it, stash it
   under a generated name. Losing a token costs a browser round-trip and,
   sometimes, a device-approval email.
3. **Tests use fake credentials and no network.** `test/test-switch.sh` runs
   against a temp `CLAUDE_CONFIG_DIR` with `CLAUDE_ACCT_OFFLINE=1`. A test that
   needs a real account is not a test we can run.
4. **Secrets never get printed.** Not in `--json`, not in errors, not in debug
   output.
5. **Say what you measured.** A claim about how Claude Code behaves names the
   version it was checked on and how. The ones in the README were checked in a
   throwaway home with the network cut off (`unshare -rn` on Linux), tracing
   file access with `strace` and pointing `ANTHROPIC_BASE_URL` at a local fake
   server. Check again after a Claude Code upgrade.

## Working on it

```bash
git clone https://github.com/psychofict/claudehop.git
cd claudehop
./install.sh              # symlinks, so your edits are live immediately
./test/test-switch.sh     # about 240 checks, under twenty seconds
```

Before opening a pull request:

```bash
./test/test-switch.sh
ruff check claudehop.py         # if you have it; CI runs it either way
shellcheck install.sh shell/*.sh test/*.sh
```

Add a check to `test/test-switch.sh` for anything you fix or add. If the
behaviour is user-visible, update `README.md` and `CHANGELOG.md` in the same
pull request.

## Things worth doing

- `hop run` on macOS. Claude Code keeps its login in the keychain there, and the
  item for a second config dir needs working out against a real Mac.
- Check whether an open interactive session (not headless mode) follows a hop,
  and how long macOS takes to notice. The README says what was measured and where.
- Verification of the macOS keychain backend against a real Mac. It is written
  against Claude Code's own `security` calls and tested through a stand-in, but
  nobody has run it on real hardware yet.
- fish shell completion (`shell/claudehop.sh` is POSIX/bash + zsh today).
- A `--verify` cache so `list --verify` doesn't re-ask the API every time.

## Style

Match what's there: plain names, comments that explain *why*, error messages
that tell the user what to do next. Keep line length near 100.
