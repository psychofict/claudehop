# Contributing

Thanks for looking. This is a small tool and it intends to stay small. Taking part means following the
[code of conduct](https://github.com/psychofict/claudehop/blob/master/CODE_OF_CONDUCT.md).

## The rules that keep it small

1. **Python 3.9+, standard library only.** No dependencies, no build step.
   `claudehop.py` must stay a single file you can read in one sitting and run
   straight from a clone. `pyproject.toml` packages that one module and nothing
   else.
2. **Never lose a login.** Any code path that replaces the live credential must
   first write what was there into a profile. If you can't identify it, stash it
   under a generated name. A refresh token is single-use, so a renewed one is
   written to disk before anything else happens, and a login two places could
   renew is renewed only by the one that holds it. Losing a token costs a browser
   round-trip and, sometimes, a device-approval email.
3. **Tests use fake credentials and no network.** `test/test-switch.sh` runs
   against a temp `CLAUDE_CONFIG_DIR` with `CLAUDE_HOP_OFFLINE=1`. Code that
   would call the network is driven in-process with the call replaced by a stub,
   and a stand-in `claude` script plays Claude Code. A test that needs a real
   account is not a test we can run.
4. **Secrets never get printed.** Not in `--json`, not in errors, not in debug
   output, not in a cache file.
5. **Say what you measured.** A claim about how Claude Code behaves names the
   version it was checked on and how. The ones in the docs were checked in a
   throwaway home with the network cut off (`unshare -rn` on Linux), tracing
   file access with `strace` and pointing `ANTHROPIC_BASE_URL` at a local fake
   server. `docs/experiments/` holds the scripts, starting with the one that
   shows an open session following a hop. Check again after a Claude Code
   upgrade, and write down a negative result too.

## Working on it

```bash
git clone https://github.com/psychofict/claudehop.git
cd claudehop
./install.sh              # symlinks, so your edits are live immediately
./test/test-switch.sh     # about 300 checks; under a minute
```

Before opening a pull request:

```bash
./test/test-switch.sh
ruff check claudehop.py                                       # CI runs it either way
shellcheck -S warning install.sh shell/claudehop.sh test/test-switch.sh
```

Add a check to `test/test-switch.sh` for anything you fix or add, and make sure
it fails without your change. If a user can see the change, update `README.md`,
`docs/commands.md` and `CHANGELOG.md` in the same pull request.

## Things worth doing

- fish shell completion ([issue 5](https://github.com/psychofict/claudehop/issues/5)), a good
  first issue. The shell glue covers bash and zsh today.
- `hop run` on macOS ([issue 1](https://github.com/psychofict/claudehop/issues/1)). Claude Code
  keeps its login in the keychain there, and the item for a second config dir needs working out on
  a real Mac. The same issue asks whether an open session follows a hop as quickly there as on
  Linux.
- The macOS keychain backend on real hardware. It is written against Claude Code's own
  `security` calls and tested through a stand-in, but nobody has run it on a Mac yet.
- Windows ([issue 7](https://github.com/psychofict/claudehop/issues/7)): whether it is wanted,
  and what it would take. Start with where Claude Code keeps its login there.

## Style

Match what's there: plain names, comments that explain *why*, error messages
that tell the user what to do next. Keep line length near 100.
