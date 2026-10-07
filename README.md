<p align="center">
  <img src="https://raw.githubusercontent.com/psychofict/claudehop/master/assets/cover.png" alt="claudehop: use several Claude Code accounts on one machine" width="560">
</p>

<h1 align="center">claudehop</h1>

<p align="center">
  <b>Use several Claude Code accounts on one machine.</b><br>
  Move every terminal to another login in one keystroke, or give each terminal its own account.<br>
  <i>One file, no dependencies, no background process.</i>
</p>

<p align="center">
  <a href="https://pypi.org/project/claudehop-cli/"><img src="https://img.shields.io/pypi/v/claudehop-cli.svg?color=FC5F00&label=pypi" alt="PyPI"></a>
  <a href="https://github.com/psychofict/claudehop/actions/workflows/ci.yml"><img src="https://github.com/psychofict/claudehop/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/psychofict/claudehop/blob/master/LICENSE"><img src="https://img.shields.io/badge/licence-MIT-FC5F00.svg" alt="Licence: MIT"></a>
  <img src="https://img.shields.io/badge/python-3.9%2B-1D1009.svg" alt="Python 3.9+">
  <img src="https://img.shields.io/badge/dependencies-none-1D1009.svg" alt="No dependencies">
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#why-claudehop">Why claudehop</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="https://github.com/psychofict/claudehop/blob/master/CHANGELOG.md">Changelog</a> ·
  <a href="https://github.com/psychofict/claudehop/blob/master/SECURITY.md">Security</a>
</p>

---

Two commands cover it.

```bash
hop work                    # every open claude moves to the work account, on its next message
hop run home -- --resume    # claude as the home account in this terminal only
```

`hop` swaps the saved login. `hop run` gives one terminal its own account and leaves your other
terminals alone, so a Max account in one terminal and a Team seat in another each spend their own
usage pool. Neither opens a browser.

```
$ hop
      NAME  EMAIL           PLAN
1.    home  me@gmail.com    max
2. *  work  me@company.com  team

hop to which? [1-2, Enter to stay] 1
switched to home (me@gmail.com, max)
```

## Install

```bash
pipx install claudehop-cli          # or: pip install --user claudehop-cli
eval "$(claudehop shell-init)"      # the `hop` alias and tab-completion
```

Put the `eval` line in your `~/.bashrc` or `~/.zshrc` and open a new terminal. `hop` and
`claudehop` are the same command. The package name carries a `-cli` suffix because PyPI holds the
bare name too close to an unrelated project; the commands don't. It needs Python 3.9 or newer and
Claude Code, on Linux or macOS. To install from a clone instead, run `./install.sh`.

Then save the login you already have, and add the others:

```bash
hop save home        # names whatever is logged in right now
hop add work         # logs in as a second account and saves it
```

## Why claudehop

claudehop is the smallest tool that does this job, and the one that plans your monthly re-login. It
does less than its two big alternatives on purpose, and where they go further the table says so.

| | claudehop | [claude-swap](https://github.com/realiti4/claude-swap) | [clauth](https://github.com/uwuclxdy/clauth) |
|---|---|---|---|
| Size of the tool | 97 KB | 1.2 MB | 15.7 MB |
| Extra packages | none | 10 | none |
| Time to start | 22 ms | 71 ms | not measured |
| Account per terminal | yes | yes | yes |
| History across accounts | shared | opt in | browse |
| Bedrock, Vertex, gateway | yes | API keys | endpoints |
| Login about to expire | warns early | when dead | when expired |
| Background process | never | optional | optional |
| Switches by itself | no | yes | yes |
| Terminal interface | no | yes | yes |
| Windows | no | yes | yes |

Size is the tool's own code: claudehop is one file, claude-swap is 24,400 lines and clauth is a
compiled binary. The cells are short on purpose; the comparison page spells each one out.

A switcher holds your refresh tokens, so a tool you can read in one sitting is a security
property, not only a size. The 30-day login window is the other gap: an account's refresh token dies
30 days after the login that issued it, and renewing does not move that date. `hop doctor` works out
the day the earliest account comes due and tells you to log them all in then, so they share one
date from then on. Neither alternative's README mentions it. Every number, how it was measured and what
the others do better is on the
[comparison page](https://github.com/psychofict/claudehop/blob/master/docs/comparison.md).

## Commands

| Command | What it does |
|---|---|
| `hop` | pick an account from a menu |
| `hop <name>` | move every open `claude` to that account's login |
| `hop run <name> [claude args]` | claude as that account in this terminal only |
| `hop add <name>` · `hop save <name>` | log in as a new account · save the login you have |
| `hop usage` | 5-hour and 7-day usage per account, when each resets |
| `hop provider <name> <command>` · `hop off` | Bedrock, Vertex or a gateway, hopped to like an account |
| `hop doctor` | check the setup and the next re-login date; `--fix` repairs what it can |
| `hop renew` · `hop whoami` · `hop rm` · `hop rename` | keep the saved logins current and tidy |

`--json` on `list`, `whoami`, `active`, `usage` and `doctor` gives output with no secrets in it,
for scripts and statuslines. The full reference is in
[docs/commands.md](https://github.com/psychofict/claudehop/blob/master/docs/commands.md).

**One account per terminal.** `hop run work` points `claude` at a config home of its own, so your
other terminals keep their account. Your settings, skills, agents, plugins, `CLAUDE.md`, prompt
history and `projects` are linked in, so the session looks like your normal one and conversations
and memory are shared across accounts. The renewed login is saved back when the session ends.
Linux only for now.

**Usage.** `hop usage` reads the usage endpoint that Claude Code itself calls. It limits other
clients, so `hop usage` asks only when you run it, remembers the last good reading, and waits out the
server's `Retry-After`. Nothing polls in the background.

```
$ hop usage
   NAME   5 HOURS            7 DAYS             NOTE
   home   98%  resets 24m    61%  resets 4d23h
*  work   42%  resets 2h14m  18%  resets 3d4h
```

## Before you hop

- A hop moves every running `claude`, not only new ones. Claude Code reads its login again before
  each message, so a conversation under way changes account on its next message and starts a new
  prompt cache. Use `hop run` when you want two accounts at once.
- Paste the `/login` URL into a private browser window. Your normal browser is already signed in as
  one of your other accounts and will authorise that one without asking.
- `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` in the environment override the saved login.
  `hop whoami` and `hop doctor` warn when either is set.
- Each account keeps its own rate limits and terms. This moves your own logins between your own
  terminals. It is not a way to pool quota.

## FAQ

*How do I use two Claude Code accounts on one machine?* Install claudehop, run `hop save home` while
logged in to the first account, then `hop add work` for the second. After that `hop work` and
`hop home` switch between them without a browser.

*Can two terminals use two different accounts at the same time?* Yes, with `hop run <name>`. A plain
`hop` cannot, because Claude Code reads its login again before every message, so a hop reaches every
open session. `hop run` gives one terminal its own config home and leaves the others alone.

*Does switching sign me out of my MCP servers?* No. The credential store holds your MCP logins under
their own key, and claudehop swaps only the Claude login block.

*Does it work with Bedrock, Vertex or a gateway?* Yes. Write a small launcher that sets the
environment variables and runs `claude "$@"`, register it with `hop provider`, and `hop <name>` sends
new `claude` commands through it. Your saved logins are never touched.

*Where are my tokens, and where do they go?* In `~/.claude/accounts/`, a folder only you can open,
with each file private to you. Tokens go only to Anthropic: `api.anthropic.com` to learn who you are
and your usage, and `platform.claude.com` to renew one.
[SECURITY.md](https://github.com/psychofict/claudehop/blob/master/SECURITY.md) has the threat model.

*How does it work, and how do I know it is right?* claudehop keeps one saved copy of each login and
swaps the live one in and out while holding Claude Code's own refresh lock. Every claim about Claude
Code's behaviour was measured and names the version it was measured on; the experiments and the
30-day login window are in
[docs/how-it-works.md](https://github.com/psychofict/claudehop/blob/master/docs/how-it-works.md). The
roughly 240 checks in `test/test-switch.sh` run against fake logins with no network.

*How does it differ from claude-swap or clauth?* It is smaller, starts faster, plans your monthly
re-login and has no background process. They add automatic switching, a terminal interface and
Windows support. The
[comparison page](https://github.com/psychofict/claudehop/blob/master/docs/comparison.md) has the
numbers and the method.

## Contributing and licence

Issues and pull requests are welcome; start with
[CONTRIBUTING.md](https://github.com/psychofict/claudehop/blob/master/CONTRIBUTING.md), and see
[the open issues](https://github.com/psychofict/claudehop/issues) for places to help, including
macOS support for `hop run`. Ask questions in
[Discussions](https://github.com/psychofict/claudehop/discussions). If claudehop saved you a
browser round-trip this morning, a star on [GitHub](https://github.com/psychofict/claudehop)
helps others find it.

MIT licence. Not affiliated with, endorsed by, or sponsored by Anthropic. "Claude" and "Claude Code" are
trademarks of Anthropic, PBC, used here only to say what this works with.

---

<p align="center">
  Made by <a href="https://ebenworks.co/">Ebenworks</a>
</p>
