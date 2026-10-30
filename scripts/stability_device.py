#!/usr/bin/env python3
"""Repeat harmless bridge operations on the paired iPhone without saving screen data."""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agent"))
from beanbao import SSHBridgeClient


APPS = ("com.apple.Preferences", "com.apple.mobilenotes", "com.apple.Maps")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path)
    parser.add_argument("--rounds", type=int, default=10)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 100:
        parser.error("--rounds must be between 1 and 100")
    bridge = SSHBridgeClient(args.host, args.identity, args.port, args.known_hosts)
    failures: list[dict[str, str | int]] = []
    timings: list[float] = []
    observations = 0
    for round_number in range(1, args.rounds + 1):
        for bundle_id in APPS:
            began = time.monotonic()
            try:
                before = bridge.observe(ui=False, ocr=False, screenshot=False)
                state = before.get("device_state", {})
                if state.get("locked") is not False or state.get("screen_on") is not True:
                    raise RuntimeError("device locked or screen off")
                bridge.act(before["observation_id"], {"action": "launch_app", "bundle_id": bundle_id})
                after = bridge.observe(ui=True, ocr=True, screenshot=True)
                observations += 1
                if after.get("frontmost_app", {}).get("bundleId") != bundle_id:
                    raise RuntimeError("foreground app mismatch")
                if not isinstance(after.get("ui"), dict) or not after["ui"]:
                    raise RuntimeError("AX tree empty")
                if not isinstance(after.get("ocr"), dict):
                    raise RuntimeError("OCR result missing")
                if not (after.get("screenshot") or {}).get("data"):
                    raise RuntimeError("screenshot empty")
                timings.append(time.monotonic() - began)
            except Exception as exc:
                failures.append({"round": round_number, "app": bundle_id, "error": type(exc).__name__ + ": " + str(exc)[:160]})
        print(json.dumps({"completed_round": round_number, "failures": len(failures)}, ensure_ascii=False), flush=True)
    result = {"rounds": args.rounds, "app_trials": args.rounds * len(APPS),
              "full_observations": observations, "failures": failures,
              "median_seconds": round(statistics.median(timings), 2) if timings else None,
              "max_seconds": round(max(timings), 2) if timings else None}
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
