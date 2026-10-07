## What this changes

<!-- One or two sentences: what a user will see differently, and why. -->

## How it was checked

- [ ] `./test/test-switch.sh` passes
- [ ] `ruff check claudehop.py` is clean
- [ ] `shellcheck -S warning install.sh shell/claudehop.sh test/test-switch.sh` is clean
- [ ] A new or changed behaviour has a check in `test/test-switch.sh`
- [ ] `README.md` and `CHANGELOG.md` are updated if a user can see the change

If this says something new about how Claude Code behaves, name the version you
measured it on and how (see rule 5 in CONTRIBUTING.md).

Never paste a token or the contents of `~/.claude/accounts/` into a pull request.
