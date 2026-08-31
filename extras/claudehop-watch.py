#!/usr/bin/env python3
"""Keep the saved logins fresh, and give notice before one has to be redone.

A Claude login lasts up to about 30 days and that date is fixed the moment you
log in: renewing rotates the token but never moves the date. So the most a
machine can do is keep the tokens it is able to keep, and warn early about the
one it cannot. Being told a week out costs a minute; finding out mid-session
costs the session.

Run it daily from claudehop-watch.timer. It renews what is safe to renew -
claudehop leaves the live login alone while sessions are running - and puts a
desktop notification up when the earliest window is inside the notice period.

  CLAUDEHOP_WARN_DAYS   days of notice to give (default 7)
  CLAUDEHOP             path to the claudehop command (default: from PATH)
"""

import json
import os
import shutil
import subprocess
import sys
import time

HOP = os.environ.get("CLAUDEHOP") or shutil.which("claudehop")
WARN_DAYS = float(os.environ.get("CLAUDEHOP_WARN_DAYS") or 7)


def hop(*args: str) -> tuple[int, str]:
    p = subprocess.run([HOP, *args], capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout


def notify(title: str, body: str, urgent: bool):
    if not shutil.which("notify-send"):
        return
    subprocess.run(
        ["notify-send", "-a", "claudehop",
         "-u", "critical" if urgent else "normal", title, body],
        check=False,
    )


def main() -> int:
    if not HOP:
        print("claudehop is not on the PATH", file=sys.stderr)
        return 1

    rc, out = hop("renew")
    for line in out.splitlines():
        print(line)

    rc, out = hop("doctor", "--json")
    try:
        plan = (json.loads(out) or {}).get("reloginPlan") or {}
    except json.JSONDecodeError:
        print("could not read the re-login plan", file=sys.stderr)
        return 1

    dead = plan.get("expired") or []
    if dead:
        notify(
            "Claude login expired",
            f"{', '.join(dead)} needs `claudehop add` - the refresh window closed.",
            urgent=True,
        )
        print(f"expired: {', '.join(dead)}")
        return 1

    first = plan.get("first")
    if not first:
        return 0
    days = (first - time.time()) / 86400
    if days > WARN_DAYS:
        return 0

    who = ", ".join(plan.get("firstAccounts") or [])
    when = time.strftime("%a %d %b", time.localtime(first))
    others = plan.get("accounts", 0) - len(plan.get("firstAccounts") or [])
    tail = (
        f" Do the other {others} the same day and every window lands together."
        if others > 0 and plan.get("spreadDays", 0) >= 1
        else ""
    )
    notify(
        f"Claude login due in {int(days)}d",
        f"{who} needs a real login by {when}.{tail}",
        urgent=days < 2,
    )
    print(f"{who} due {when} ({int(days)}d)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
