#!/usr/bin/env python3
"""Does an open, interactive `claude` session follow a login swap between two messages?

A fake API server on 127.0.0.1 records the bearer token of every request. `claude`
runs in a pseudo-terminal, on its normal interactive screen, with a throwaway HOME
and CLAUDE_CONFIG_DIR holding a made-up login. After the first answer the credential
file is replaced atomically, the way `hop` replaces it, and a second message is sent.
The output lists each request with the login it carried and its time after the swap.

    unshare -rn sh -c 'ip link set lo up && python3 session-follows-swap.py "$(readlink -f "$(command -v claude)")" 0'

`unshare -rn` cuts the network so nothing can leave the machine; without it the
script still only talks to its own local server. The second argument is how many
seconds to wait after the swap before typing the next message.

Result, 13 October 2026, Linux, Claude Code 2.1.284: three runs out of three sent the
first message with the old login and the second, 0.9 s after the swap, with the new
one. Claude Code left the swapped file as it was. It reads the file, so this says
nothing about macOS, where the login is in the keychain.
"""
import fcntl, http.server, json, os, pty, re, select, shutil, signal, struct, sys, tempfile, termios, threading, time

CLAUDE = sys.argv[1]
SWAP_WAIT = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]|\x1b[=>]")
LOG = []
REPLIES = iter([f"PONG{i}" for i in range(1, 100)])


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _rec(self, body=b""):
        auth = self.headers.get("Authorization", "") or ""
        key = self.headers.get("x-api-key", "")
        try:
            j = json.loads(body or b"{}")
        except ValueError:
            j = {}
        LOG.append({"t": time.time(), "method": self.command, "path": self.path, "auth": auth[-12:],
                    "xkey": key[-8:], "stream": j.get("stream"), "model": j.get("model"),
                    "last_user": _last_user(j)})
        return j

    def do_GET(self):
        self._rec()
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        j = self._rec(self.rfile.read(n))
        if not self.path.startswith("/v1/messages") or "count_tokens" in self.path:
            body = json.dumps({"input_tokens": 10}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        text = next(REPLIES)
        LOG[-1]["reply"] = text
        msg = {"id": "msg_" + text, "type": "message", "role": "assistant", "model": j.get("model") or "x",
               "content": [], "stop_reason": None, "stop_sequence": None,
               "usage": {"input_tokens": 5, "output_tokens": 1}}
        if not j.get("stream"):
            msg.update(content=[{"type": "text", "text": text}], stop_reason="end_turn")
            body = json.dumps(msg).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        evs = [("message_start", {"type": "message_start", "message": msg}),
               ("content_block_start", {"type": "content_block_start", "index": 0,
                                        "content_block": {"type": "text", "text": ""}}),
               ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                        "delta": {"type": "text_delta", "text": text}}),
               ("content_block_stop", {"type": "content_block_stop", "index": 0}),
               ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                  "usage": {"output_tokens": 1}}),
               ("message_stop", {"type": "message_stop"})]
        for name, data in evs:
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()


def _last_user(j):
    for m in reversed(j.get("messages") or []):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                return c[-40:]
            for part in reversed(c or []):
                if isinstance(part, dict) and part.get("type") == "text":
                    return part["text"][-40:]
    return None


def creds(tok):
    far = int((time.time() + 20 * 86400) * 1000)
    return {"claudeAiOauth": {"accessToken": tok, "refreshToken": "r-" + tok, "expiresAt": far,
                              "refreshTokenExpiresAt": far + 86400000,
                              "scopes": ["user:inference", "user:profile", "user:sessions:claude_code"],
                              "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}}


def swap(cfg, tok):
    tmp = os.path.join(cfg, ".credentials.json.tmp-swap")
    with open(tmp, "w") as f:
        json.dump(creds(tok), f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(cfg, ".credentials.json"))


def main():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    root = tempfile.mkdtemp(prefix="issue2-")
    home, cfg, work = (os.path.join(root, d) for d in ("home", "cfg", "work"))
    for d in (home, cfg, work):
        os.makedirs(d)
    with open(os.path.join(cfg, ".credentials.json"), "w") as f:
        json.dump(creds("tok-OLD-login"), f)
    os.chmod(os.path.join(cfg, ".credentials.json"), 0o600)
    with open(os.path.join(cfg, ".claude.json"), "w") as f:
        json.dump({"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 5,
                   "oauthAccount": {"emailAddress": "test@example.invalid", "accountUuid": "u-test",
                                    "organizationUuid": "o-test"},
                   "projects": {work: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}}}, f)
    env = {"PATH": os.environ["PATH"], "HOME": home, "CLAUDE_CONFIG_DIR": cfg, "TERM": "xterm-256color",
           "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}", "DISABLE_AUTOUPDATER": "1",
           "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "LANG": "C.UTF-8"}
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execve(CLAUDE, [CLAUDE], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    screen = []

    def pump(secs, until=None):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                screen.append(ANSI.sub("", data.decode(errors="replace")))
            if until and re.search(until, "".join(screen)[-6000:]):
                return True
        return False

    def typ(text):
        for ch in text:
            os.write(fd, ch.encode())
            time.sleep(0.03)
        time.sleep(0.4)
        os.write(fd, b"\r")

    pump(10, r"for shortcuts|Try \"|>\s")
    tail = "".join(screen)[-3000:]
    if re.search(r"(?i)trust", tail):
        os.write(fd, b"\r")
        pump(4)
    typ("say one word")
    got1 = pump(25, r"PONG\d")
    t_swap = time.time()
    swap(cfg, "tok-NEW-login")
    pump(SWAP_WAIT)
    typ("say another word")
    got2 = pump(25, r"PONG\d+[\s\S]*PONG\d+")
    os.kill(pid, signal.SIGTERM)
    time.sleep(0.5)
    srv.shutdown()
    final = json.load(open(os.path.join(cfg, ".credentials.json")))["claudeAiOauth"]["accessToken"]
    out = {"replies_seen": [got1, got2], "swap_at": t_swap, "swap_wait": SWAP_WAIT,
           "requests": [dict(r, t=round(r["t"] - t_swap, 2)) for r in LOG],
           "credential_file_after": final, "screen_tail": "".join(screen)[-1500:]}
    print(json.dumps(out, indent=1))
    shutil.rmtree(root, ignore_errors=True)


main()
