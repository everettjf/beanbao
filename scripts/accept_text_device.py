#!/usr/bin/env python3
"""Run the reversible text-open acceptance cases on an unlocked paired phone."""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import time
from pathlib import Path


CASES = (
    ("打开设置", "com.apple.Preferences"),
    ("打开通讯录", "com.apple.MobileAddressBook"),
    ("打开备忘录", "com.apple.mobilenotes"),
    ("打开地图", "com.apple.Maps"),
    ("请帮我打开一下地图", "com.apple.Maps"),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path)
    args = parser.parse_args()
    ssh = ["ssh", "-i", str(args.identity), "-p", str(args.port),
           "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
           f"mobile@{args.host}"]
    if args.known_hosts:
        ssh[1:1] = ["-o", f"UserKnownHostsFile={args.known_hosts}"]

    def remote(command: str, allowed_exit: tuple[int, ...] = (0,)) -> str:
        result = subprocess.run([*ssh, command], capture_output=True, text=True, timeout=20)
        if result.returncode not in allowed_exit:
            raise RuntimeError(f"device command failed ({result.returncode}): {result.stderr[:160]}")
        return result.stdout

    def observe() -> dict:
        return json.loads(remote("beanbaoctl '{\"op\":\"observe\"}'"))

    def ready(observation: dict) -> bool:
        state = observation.get("device_state", {})
        return (observation.get("ok") is True and state.get("locked_known") is True and
                state.get("locked") is False and state.get("screen_on_known") is True and
                state.get("screen_on") is True)

    def status() -> dict:
        return json.loads(remote("beanbaoagentctl status"))

    initial = observe()
    if not ready(initial):
        raise SystemExit("Phone is locked or screen is off; unlock it before text acceptance.")
    previous = status()
    if previous.get("ok") is not True or previous.get("running"):
        raise SystemExit("Agent service is unavailable or busy.")

    for task, expected_bundle in CASES:
        remote("uiopen --bundleid dev.beanbao.app")
        for _ in range(12):
            source = observe()
            if not ready(source):
                raise RuntimeError("Phone locked during text acceptance.")
            if source.get("frontmost_app", {}).get("bundleId") == "dev.beanbao.app":
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("BeanBao did not become foreground.")

        started = json.loads(remote("beanbaoagentctl start " + shlex.quote(task)))
        service_id = started.get("service_id")
        task_id = started.get("task_id")
        if started.get("ok") is not True or not service_id or not task_id or \
                service_id != previous.get("service_id") or task_id == previous.get("task_id"):
            raise RuntimeError(f"Task was rejected or status identity did not advance: {task}")

        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            current = status()
            if current.get("service_id") != service_id or current.get("task_id") != task_id:
                raise RuntimeError("Agent service or task changed during acceptance.")
            if not current.get("running"):
                break
            time.sleep(0.3)
        else:
            raise RuntimeError(f"Task did not finish within 45 seconds: {task}")
        if current.get("phase") != "done":
            raise RuntimeError(f"Task was not completed: {task}: {current.get('message', '')}")

        for _ in range(2):
            confirmed = observe()
            if not ready(confirmed) or confirmed.get("frontmost_app", {}).get("bundleId") != expected_bundle:
                raise RuntimeError(f"Actual foreground did not match completed task: {task}")
            time.sleep(0.2)
        print(json.dumps({"task": task, "phase": "done", "frontmost": expected_bundle},
                         ensure_ascii=False), flush=True)
        previous = current

    rejected = json.loads(remote("beanbaoagentctl start " + shlex.quote("请帮我打开地图并发消息"),
                                 allowed_exit=(0, 1)))
    after = status()
    if rejected.get("ok") is not False or "首版只接受" not in rejected.get("error", "") or \
            after.get("task_id") != previous.get("task_id") or \
            after.get("service_id") != previous.get("service_id") or after.get("running"):
        raise RuntimeError("Forbidden compound instruction was accepted or changed task identity.")
    print(json.dumps({"forbidden_compound_task": "rejected", "cases_passed": len(CASES)},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
