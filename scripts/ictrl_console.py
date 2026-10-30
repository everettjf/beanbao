#!/usr/bin/env python3
"""Temporary development console for the already-paired Copy APP iCTRL runner."""
import json
import sys

from copyapp.ictrl import ICtrlClient
from copyapp.usb_tunnel import ictrl_tunnel


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: ictrl_console.py UDID")
    with ictrl_tunnel(sys.argv[1], require_xctest=True) as port:
        client = ICtrlClient(port=port)
        print(json.dumps({"ready": True, "port": port}), flush=True)
        for line in sys.stdin:
            try:
                request = json.loads(line)
                if request.get("cmd") == "quit":
                    break
                if request.get("cmd") == "call":
                    result = client.call_ui(request["method"], request.get("params") or {})
                elif request.get("cmd") == "shot":
                    result = {"path": str(client.screenshot(__import__("pathlib").Path(request["path"])))}
                else:
                    raise ValueError("unknown command")
                print(json.dumps({"ok": True, "result": result}, ensure_ascii=False), flush=True)
            except Exception as exc:
                print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
