#!/usr/bin/env python3
"""Repeat reversible HID/text actions inside BeanBao's own text screen."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agent"))
from beanbao import SSHBridgeClient


def find_tap(observation: dict, text: str) -> dict[str, float]:
    for element in observation.get("ui", {}).get("elements", []):
        if element.get("text") == text and isinstance(element.get("tap"), dict):
            return {"x": element["tap"]["x"], "y": element["tap"]["y"]}
    raise RuntimeError(f"BeanBao control unavailable: {text}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=10)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 100:
        parser.error("--rounds must be between 1 and 100")
    ssh = ["ssh", "-i", str(args.identity), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", f"mobile@{args.host}"]
    bridge = SSHBridgeClient(args.host, args.identity)
    counts = {"tap": 0, "input_text": 0, "press_key": 0, "swipe": 0}
    failures: list[dict[str, str | int]] = []
    for number in range(1, args.rounds + 1):
        try:
            subprocess.run([*ssh, "uiopen --bundleid dev.beanbao.app"], check=True, capture_output=True, timeout=12)
            time.sleep(0.5)
            observation = bridge.observe(ui=True)
            if observation.get("frontmost_app", {}).get("bundleId") != "dev.beanbao.app":
                raise RuntimeError("BeanBao is not foreground")
            bridge.act(observation["observation_id"], {"action": "tap", **find_tap(observation, "清空输入")})
            counts["tap"] += 1

            observation = bridge.observe(ui=True)
            bridge.act(observation["observation_id"], {"action": "tap", **find_tap(observation, "例如：打开地图")})
            counts["tap"] += 1

            marker = f"BeanBao{number}X"
            observation = bridge.observe(ui=False)
            bridge.act(observation["observation_id"], {"action": "input_text", "text": marker})
            counts["input_text"] += 1

            observation = bridge.observe(ui=False)
            bridge.act(observation["observation_id"], {"action": "press_key", "key": "backspace"})
            counts["press_key"] += 1

            observation = bridge.observe(ui=True)
            texts = [str(element.get("text", "")) for element in observation.get("ui", {}).get("elements", [])]
            if not any(f"BeanBao{number}" in text for text in texts):
                raise RuntimeError("typed text not visible in BeanBao")
            bridge.act(observation["observation_id"], {"action": "swipe",
                                                       "x1": 350, "y1": 185, "x2": 350, "y2": 220})
            counts["swipe"] += 1
            after = bridge.observe(ui=False)
            if after.get("frontmost_app", {}).get("bundleId") != "dev.beanbao.app":
                raise RuntimeError("foreground app changed unexpectedly")
        except Exception as exc:
            failures.append({"round": number, "error": type(exc).__name__ + ": " + str(exc)[:160]})
        print(json.dumps({"round": number, "counts": counts, "failures": len(failures)}, ensure_ascii=False), flush=True)
    print(json.dumps({"rounds": args.rounds, "counts": counts, "failures": failures}, ensure_ascii=False))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
