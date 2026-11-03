#!/usr/bin/env python3
"""Verify a saved research/PDF/draft workflow after a device reboot.

Select by workflow ID through the Agent. The Sessions table's direct AX row
coordinates can be displaced from the rendered rows on the tested iOS 26 phone.
No email composer is opened and no message is sent.
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agent"))
from beanbao import BridgeError, SSHBridgeClient


EXPECTED_TOOLS = (
    "web_search", "app_lookup", "report_compose", "app_prepare",
    "pdf_render", "mail_prepare",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path, required=True)
    parser.add_argument("--workflow-id", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}",
                        args.workflow_id):
        parser.error("--workflow-id must be a UUID")

    ssh = ["ssh", "-i", str(args.identity), "-p", str(args.port),
           "-o", f"UserKnownHostsFile={args.known_hosts}",
           "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
           f"mobile@{args.host}"]
    bridge = SSHBridgeClient(args.host, args.identity, args.port, args.known_hosts)

    def remote(command: str) -> str:
        return subprocess.check_output([*ssh, command], text=True, timeout=20)

    def remote_json(command: str) -> dict:
        result = json.loads(remote(command))
        if result.get("ok") is not True:
            raise RuntimeError("Device command did not succeed")
        return result

    def observe() -> dict:
        result = bridge.observe(ui=True)
        state = result.get("device_state", {})
        if state.get("locked_known") is not True or state.get("locked") is not False or \
                state.get("screen_on_known") is not True or state.get("screen_on") is not True:
            raise RuntimeError("Phone locked or screen off during workflow acceptance")
        return result

    def labels(result: dict) -> set[str]:
        return {str(e.get("text")) for e in result.get("ui", {}).get("elements", [])
                if e.get("text")}

    def tap_label(result: dict, label: str) -> None:
        control = next((e for e in result.get("ui", {}).get("elements", [])
                        if e.get("text") == label and isinstance(e.get("tap"), dict)), None)
        if not control or bridge.act(result["observation_id"],
                                     {"action": "tap", **control["tap"]}).get("ok") is not True:
            raise RuntimeError(f"Could not tap {label}")

    details = remote_json("beanbaoagentctl workflow-details " + shlex.quote(args.workflow_id))
    steps = details.get("steps", [])
    if details.get("id") != args.workflow_id or details.get("phase") != "waitingForUser" or \
            tuple(step.get("tool") for step in steps) != EXPECTED_TOOLS or \
            any(step.get("state") != "completed" for step in steps):
        raise RuntimeError("Saved workflow steps or phase did not survive")

    if remote_json("beanbaoagentctl status").get("running"):
        raise RuntimeError("Agent is busy; do not switch the active workflow")
    remote_json("beanbaoagentctl select-workflow " + shlex.quote(args.workflow_id))
    status = remote_json("beanbaoagentctl status")
    if status.get("task_id") != args.workflow_id or status.get("phase") != "waiting_for_user" or \
            not status.get("report_path") or not status.get("mail_draft_path"):
        raise RuntimeError("Saved workflow did not restore to Agent status")
    sizes = []
    for key in ("report_path", "mail_draft_path"):
        path = status[key]
        if not path.startswith("/var/mobile/Library/Application Support/BeanBao/workflows/"):
            raise RuntimeError("Artifact path is outside the workflow directory")
        size = int(remote("wc -c < " + shlex.quote("/rootfs/private" + path)).strip())
        if size <= 0:
            raise RuntimeError("Saved artifact is empty")
        sizes.append(size)

    remote("uiopen --bundleid dev.beanbao.app")
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            screen = observe()
        except BridgeError:
            time.sleep(.3)
            continue
        if screen.get("frontmost_app", {}).get("bundleId") != "dev.beanbao.app":
            time.sleep(.3)
            continue
        visible = labels(screen)
        if {"Ready for review", "View PDF report", "Review email draft"} <= visible:
            break
        if "Saved workflows" in visible and "BeanBao" in visible:
            tap_label(screen, "BeanBao")
        time.sleep(.3)
    else:
        raise RuntimeError("Saved workflow review controls did not appear")

    tap_label(screen, "View PDF report")
    time.sleep(.7)
    preview = observe()
    if "report, Actions Menu" not in labels(preview):
        raise RuntimeError("Saved PDF did not open in the app viewer")
    tap_label(preview, "BeanBao")
    time.sleep(.4)
    restored = observe()
    if "Ready for review" not in labels(restored):
        raise RuntimeError("Saved workflow review state disappeared after PDF preview")
    print(json.dumps({"workflow_id": args.workflow_id, "steps": len(steps),
                      "pdf_bytes": sizes[0], "draft_bytes": sizes[1],
                      "review_state": "passed", "pdf_viewer": "passed"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
