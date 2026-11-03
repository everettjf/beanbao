#!/usr/bin/env python3
"""Exercise BeanBao's visible text entry on an unlocked paired iPhone.

Only a uniquely named test note is created. Contact UI is not collected;
personal note contents, screenshots, and model credentials are not printed.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agent"))
from beanbao import BridgeError, SSHBridgeClient

CASES = ("open_contacts", "create_test_note", "map_search", "forbidden_compound")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    args = parser.parse_args()

    ssh = ["ssh", "-i", str(args.identity), "-p", str(args.port),
           "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
           f"mobile@{args.host}"]
    if args.known_hosts:
        ssh[1:1] = ["-o", f"UserKnownHostsFile={args.known_hosts}"]
    bridge = SSHBridgeClient(args.host, args.identity, args.port, args.known_hosts)

    def remote(command: str) -> str:
        return subprocess.check_output([*ssh, command], text=True, timeout=20)

    def status() -> dict:
        return json.loads(remote("beanbaoagentctl status"))

    def observe(*, ui: bool = True) -> dict:
        result = bridge.observe(ui=ui)
        state = result.get("device_state", {})
        if state.get("locked_known") is not True or state.get("locked") is not False or \
                state.get("screen_on_known") is not True or state.get("screen_on") is not True:
            raise RuntimeError("Phone locked or screen off during App text acceptance")
        return result

    def tap_label(label: str, *, uppermost: bool = False) -> None:
        observation = observe()
        points = [e["tap"] for e in observation.get("ui", {}).get("elements", [])
                  if e.get("text") == label and isinstance(e.get("tap"), dict)]
        if not points:
            raise RuntimeError(f"Visible control unavailable: {label}")
        point = min(points, key=lambda p: p["y"]) if uppermost else points[0]
        if bridge.act(observation["observation_id"], {"action": "tap", **point}).get("ok") is not True:
            raise RuntimeError(f"Tap failed: {label}")

    def submit(task: str, *, forbidden: bool = False) -> dict:
        before = status()
        if before.get("ok") is not True or before.get("running"):
            raise RuntimeError("Agent unavailable or busy before App submission")
        remote("uiopen --bundleid dev.beanbao.app")
        # uiopen may briefly show a restored session before the composer is ready.
        for _ in range(24):
            try:
                source = observe()
            except BridgeError:
                time.sleep(.25)
                continue
            if source.get("frontmost_app", {}).get("bundleId") != "dev.beanbao.app":
                time.sleep(.25)
                continue
            if any(e.get("text") == "Clear" for e in source.get("ui", {}).get("elements", [])):
                break
            back = next((e.get("tap") for e in source.get("ui", {}).get("elements", [])
                         if e.get("text") == "BeanBao" and "Back" in (e.get("aliases") or [])
                         and isinstance(e.get("tap"), dict)), None)
            if back:
                if bridge.act(source["observation_id"], {"action": "tap", **back}).get("ok") is not True:
                    raise RuntimeError("Could not return to BeanBao's task composer")
            time.sleep(.25)
        else:
            raise RuntimeError("BeanBao's task composer did not become ready")

        tap_label("Clear")
        tap_label("e.g. Open Maps")
        source = observe()
        if bridge.act(source["observation_id"], {"action": "input_text", "text": task}).get("ok") is not True:
            raise RuntimeError("Could not enter text")
        source = observe()
        visible = [str(e.get("text", "")) for e in source.get("ui", {}).get("elements", [])]
        if task not in visible:
            raise RuntimeError("Entered instruction is not visible")
        starts = [e["tap"] for e in source.get("ui", {}).get("elements", [])
                  if e.get("text") == "Start" and isinstance(e.get("tap"), dict)]
        if len(starts) < 2:
            raise RuntimeError("Keyboard accessory Start button is missing")
        # The page button can sit slightly above the keyboard toolbar after
        # layout changes; the toolbar's Start is the rightmost visible one.
        if bridge.act(source["observation_id"],
                      {"action": "tap", **max(starts, key=lambda p: p["x"])}).get("ok") is not True:
            raise RuntimeError("Keyboard accessory Start tap failed")

        deadline = time.monotonic() + (25 if forbidden else 50)
        while time.monotonic() < deadline:
            current = status()
            if forbidden:
                if current.get("service_id") != before.get("service_id"):
                    raise RuntimeError("Agent service changed during forbidden instruction")
                app = observe()
                if app.get("frontmost_app", {}).get("bundleId") != "dev.beanbao.app":
                    raise RuntimeError("Forbidden instruction changed foreground")
                texts = [str(e.get("text", "")) for e in app.get("ui", {}).get("elements", [])]
                if current.get("task_id") == before.get("task_id") and "Not started" in texts:
                    return current
                # The Agent may create an incomplete task record before its
                # allowlist rejects the compound request. That is safe only
                # when no action ran and the App shows the rejection.
                if current.get("task_id") != before.get("task_id") and \
                        current.get("phase") == "error" and not current.get("running") and \
                        current.get("message") == "I could not identify one supported action. Try a clearer request." and \
                        "Incomplete" in texts and current["message"] in texts:
                    return current
            elif current.get("task_id") and current.get("task_id") != before.get("task_id") and \
                    not current.get("running"):
                if current.get("service_id") != before.get("service_id") or current.get("phase") != "done":
                    raise RuntimeError(f"App task did not finish cleanly: {current.get('phase')}")
                return current
            time.sleep(.3)
        raise RuntimeError("App submission did not reach the expected result")

    def confirm_frontmost(bundle: str, *, ui: bool = False) -> dict:
        for _ in range(2):
            result = observe(ui=ui)
            if result.get("frontmost_app", {}).get("bundleId") != bundle:
                raise RuntimeError(f"Actual foreground is not {bundle}")
            time.sleep(.2)
        return result

    if "open_contacts" in args.cases:
        submit("Open Contacts")
        confirm_frontmost("com.apple.MobileAddressBook")
        print(json.dumps({"app_case": "open_contacts", "result": "passed"}), flush=True)

    if "create_test_note" in args.cases:
        marker = "BeanBao test " + uuid.uuid4().hex[:8]
        submit("Create note: " + marker)
        note = confirm_frontmost("com.apple.mobilenotes", ui=True)
        note_texts = [str(e.get("text", "")) for e in note.get("ui", {}).get("elements", [])]
        if not any(marker in text for text in note_texts):
            raise RuntimeError("Unique test note title was not visible after completion")
        print(json.dumps({"app_case": "create_test_note", "result": "passed", "marker": marker},
                         ensure_ascii=False), flush=True)

    if "map_search" in args.cases:
        submit("Search Maps for Golden Gate Bridge")
        map_view = confirm_frontmost("com.apple.Maps", ui=True)
        map_matches = [e for e in map_view.get("ui", {}).get("elements", [])
                       if "Golden Gate Bridge" in str(e.get("text", ""))]
        positions = [e["tap"]["y"] for e in map_matches if isinstance(e.get("tap"), dict)]
        if len(positions) < 2 or max(positions) - min(positions) < 100:
            raise RuntimeError("Map marker and place card were not both visible")
        print(json.dumps({"app_case": "map_search", "result": "passed"}), flush=True)

    if "forbidden_compound" in args.cases:
        submit("Open Maps and send a message", forbidden=True)
        print(json.dumps({"app_case": "forbidden_compound", "result": "rejected"}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
