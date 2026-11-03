#!/usr/bin/env python3
"""Compare Settings AX tap points with screenshot OCR coordinates.

Read-only diagnostic for the paired iOS 26 phone. It prints only fixed control
names and numeric offsets, never the screenshot or unrelated screen text.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agent"))
from beanbao import SSHBridgeClient


LABELS = ("Airplane Mode", "General", "Accessibility")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path, required=True)
    parser.add_argument("--require-aligned", action="store_true",
                        help="fail if AX and OCR points differ by more than 20 screen points")
    parser.add_argument("--verify-ocr-tap", action="store_true",
                        help="open General at its OCR point, then return to Settings")
    args = parser.parse_args()

    bridge = SSHBridgeClient(args.host, args.identity, args.port, args.known_hosts)
    screen = bridge.observe(ui=True, ocr=True)
    state = screen.get("device_state", {})
    if state.get("locked_known") is not True or state.get("locked") is not False or \
            state.get("screen_on_known") is not True or state.get("screen_on") is not True:
        raise RuntimeError("Phone is locked or screen is off")
    if screen.get("frontmost_app", {}).get("bundleId") != "com.apple.Preferences":
        raise RuntimeError("Open the top-level Settings screen before this diagnostic")

    ax = {e.get("text"): e.get("tap", {}) for e in screen.get("ui", {}).get("elements", [])
          if e.get("text") in LABELS and isinstance(e.get("tap"), dict)}
    ocr = {e.get("text"): e.get("tap", {}) for e in screen.get("ocr", {}).get("texts", [])
           if e.get("text") in LABELS and isinstance(e.get("tap"), dict)}
    offsets = {name: round(ocr[name]["y"] - ax[name]["y"])
               for name in LABELS if name in ax and name in ocr}
    if len(offsets) < 2:
        raise RuntimeError("Fewer than two known Settings labels were observed by both AX and OCR")

    median = round(statistics.median(offsets.values()))
    aligned = all(abs(delta) <= 20 for delta in offsets.values())
    consistent = all(abs(delta - median) <= 20 for delta in offsets.values())
    result = {"bundle_id": "com.apple.Preferences", "offset_y_by_label": offsets,
              "median_offset_y": median, "aligned": aligned,
              "consistent_translation": consistent}
    if args.verify_ocr_tap:
        if "General" not in ocr:
            raise RuntimeError("OCR did not find General")
        try:
            tapped = bridge.act(screen["observation_id"],
                                {"action": "tap", **ocr["General"]})
            if tapped.get("ok") is not True:
                raise RuntimeError("OCR tap was rejected")
            time.sleep(.5)
            opened = bridge.observe(ui=True)
            if not any(e.get("text") == "About" for e in opened.get("ui", {}).get("elements", [])):
                raise RuntimeError("General did not open at the OCR point")
            result["ocr_tap_verified"] = True
        finally:
            current = bridge.observe(ui=True)
            back = next((e for e in current.get("ui", {}).get("elements", [])
                         if e.get("text") == "Settings" and isinstance(e.get("tap"), dict)), None)
            if back:
                bridge.act(current["observation_id"], {"action": "tap", **back["tap"]})
            time.sleep(.4)
            restored = bridge.observe(ui=True)
            if not any(e.get("text") == "General" for e in restored.get("ui", {}).get("elements", [])):
                raise RuntimeError("Settings top level was not restored")
    print(json.dumps(result, sort_keys=True))
    return 0 if aligned or not args.require_aligned else 1


if __name__ == "__main__":
    raise SystemExit(main())
