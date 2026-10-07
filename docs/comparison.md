# claudehop compared with other Claude Code account switchers

claudehop is the smallest of the three tools below and, going by their READMEs, the only one that
plans your monthly re-login. It does less than claude-swap and clauth, on purpose. This page gives every number
behind the table in the [README](https://github.com/psychofict/claudehop#readme), says how each
was measured, and lists where the others go further.

Checked on 2026-10-07 against claudehop 1.7.0, claude-swap 0.26.0 (PyPI) and clauth 0.17.0
(GitHub release). The feature rows come from each project's own README, so a feature a README
does not mention may still exist. If a row is wrong, open an issue and it will be fixed.

| | claudehop | claude-swap | clauth |
|---|---|---|---|
| Size of the tool | 97 KB, one file | 1.2 MB, 24,400 lines | 15.7 MB binary |
| Extra packages to install | none | 10 | none (a binary) |
| Time to start (`--version`) | 22 ms | 71 ms | not measured |
| A different account per terminal | yes, `hop run` | yes, `cswap run` | yes, `clauth start` |
| Chat history across accounts | shared by default | per account, unless `--share-history` | browse and resume across accounts |
| Usage and reset times | `hop usage`, when you ask | live dashboard | live monitor |
| Switches by itself near a limit | no | yes | yes |
| Bedrock, Vertex or a gateway | yes, hop to it like an account | API keys only | custom API endpoints |
| Login about to expire | warns 14 days ahead and plans one sitting | quarantines it once the token has died | reports an expired login |
| Needs a background process | never | optional | optional daemon |
| Windows | no | yes | yes |
| Terminal interface | no | yes | yes |

## Where claudehop is ahead

Size you can read. A switcher holds your refresh tokens, so being able to read all of it in one
sitting is a security property. claudehop is one 97 KB file that uses only the Python standard
library. claude-swap is 24,400 lines of its own code plus ten packages, a terminal interface
framework and what it needs. clauth is a 15.7 MB compiled binary.

Start-up. `--version` takes 22 ms against 71 ms, median of 15 runs on a warm cache. Starting
Python alone takes 8 ms, so claudehop adds about 14 ms of its own and claude-swap about 63 ms.

The 30-day login window. An account's refresh token dies 30 days after the login that issued
it, and renewing does not move that date. With several accounts the dates drift apart and you
are sent to the browser once per account per month. `hop doctor` works out the day the earliest
one comes due and tells you to log everything in on that day, so they share one date from then
on. The measurement is in [how it works](https://github.com/psychofict/claudehop/blob/master/docs/how-it-works.md).
The claude-swap and clauth READMEs do not mention this window.

Providers. Amazon Bedrock, Vertex and a gateway are not logins. claudehop lets you register
a launcher for each and hop to it like an account without touching a saved login. claude-swap
accepts API keys as accounts but documents no Bedrock or Vertex support.

One shared history. A `hop run` session links your settings, skills, agents, plugins, `CLAUDE.md`,
`projects` (conversations and memory) and prompt history, so it looks like your normal session.
claude-swap keeps chat history per account unless you pass `--share-history`.

No background process. claudehop runs when you type a command and then exits. Nothing polls,
nothing listens.

Claims come with a version. Everything the README says about how Claude Code behaves was
measured in a throwaway home with the network cut off, and names the Claude Code version. Re-run
the experiments after an upgrade; the method is in
[CONTRIBUTING](https://github.com/psychofict/claudehop/blob/master/CONTRIBUTING.md).

## Where the others go further

claude-swap and clauth switch for you before a rate limit, show live usage, have a terminal
interface and run on Windows. claude-swap also has far more tests: 2,183 test functions against
claudehop's 236 checks (different units, so read this as scale, not a ratio). claudehop has no
terminal interface, no automatic switching and no Windows support. Automatic switching is
deliberately absent: a hop moves every open session on its next message, so it should never
happen unasked.

## How to repeat the numbers

```bash
# size and packages, in clean environments
uv venv a && uv pip install --python a/bin/python claudehop-cli
uv venv b && uv pip install --python b/bin/python claude-swap
du -sh a b
python -c "import importlib.metadata as m; print(len(list(m.distributions())))"   # run with each venv's python, from a neutral directory

# start-up: 15 runs each, take the median
for i in $(seq 15); do /usr/bin/time -f %e a/bin/hop --version; done
for i in $(seq 15); do /usr/bin/time -f %e b/bin/cswap --version; done

# the competitor's own code and tests
wc -l b/lib/python3*/site-packages/claude_swap/*.py | tail -1
gh api repos/realiti4/claude-swap/tarball/HEAD | tar xz && grep -rhE '^\s*(async )?def test_' */tests | wc -l
```

The run in the table used a Linux x86-64 machine, Python 3.12, and an environment variable set to
a throwaway home so no real account was read.
