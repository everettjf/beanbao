#!/usr/bin/env python3
"""Watch the idle BeanBao launchd service for an hour without saving screen data."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--minutes", type=int, default=60)
    parser.add_argument("--interval", type=int, default=15)
    args = parser.parse_args()
    if not 1 <= args.minutes <= 240 or not 5 <= args.interval <= 60:
        parser.error("minutes must be 1–240 and interval 5–60 seconds")
    ssh = ["ssh", "-i", str(args.identity), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", f"mobile@{args.host}"]

    def query() -> tuple[int, dict]:
        result = subprocess.run([*ssh, "launchctl print user/501/dev.beanbao.agent"],
                                capture_output=True, text=True, timeout=12, check=True)
        match = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.MULTILINE)
        if not match:
            raise RuntimeError("launchd has no running BeanBao PID")
        status = subprocess.run([*ssh, "beanbaoagentctl status"], capture_output=True,
                                text=True, timeout=12, check=True)
        payload = json.loads(status.stdout)
        if not payload.get("ok") or payload.get("running"):
            raise RuntimeError("service unavailable or unexpected task running")
        return int(match.group(1)), payload

    began = time.monotonic()
    pid, state = query()
    samples = 1
    deadline = began + args.minutes * 60
    next_report = began + 300
    while time.monotonic() < deadline:
        time.sleep(min(args.interval, max(0, deadline - time.monotonic())))
        current_pid, state = query()
        samples += 1
        if current_pid != pid:
            raise RuntimeError(f"BeanBao service restarted: initial PID {pid}, current PID {current_pid}")
        if time.monotonic() >= next_report:
            print(json.dumps({"elapsed_minutes": round((time.monotonic() - began) / 60, 1),
                              "samples": samples, "service_pid_stable": True}, ensure_ascii=False), flush=True)
            next_report += 300
    print(json.dumps({"elapsed_minutes": round((time.monotonic() - began) / 60, 1),
                      "samples": samples, "service_pid_stable": True,
                      "last_phase": state.get("phase")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
