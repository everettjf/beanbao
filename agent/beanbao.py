#!/usr/bin/env python3
"""Text-first BeanBao agent. The bridge accepts exactly one action per observation."""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shlex
import socket
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Protocol

ALLOWED_APPS = {
    "com.apple.Preferences": ("设置", "settings"),
    "com.apple.mobilenotes": ("备忘录", "notes"),
    "com.apple.Maps": ("地图", "maps"),
}
ALLOWED_ACTIONS = {"launch_app", "tap", "swipe", "input_text", "press_key", "done"}
SECRET_PATTERNS = (
    re.compile(r"\bsk-[A-Za-z0-9_-]{16,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\b(?:api[_ -]?key|bearer token)\s*[:=]\s*\S{12,}", re.IGNORECASE),
)


def contains_visible_secret(value: Any) -> bool:
    """Best-effort guard on OCR/AX text before any external model request."""
    if isinstance(value, str):
        return any(pattern.search(value) for pattern in SECRET_PATTERNS)
    if isinstance(value, dict):
        return any(contains_visible_secret(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_visible_secret(item) for item in value)
    return False


class BridgeError(RuntimeError):
    pass


class BridgeClient:
    def __init__(self, path: str, token: str):
        if len(token) != 64:
            raise ValueError("bridge token must be 64 hex characters")
        self.path, self.token = path, token

    def request(self, payload: dict[str, Any]) -> dict[str, Any]:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(15)
            conn.connect(self.path)
            conn.sendall(json.dumps({"token": self.token, **payload}, ensure_ascii=False).encode() + b"\n")
            data = bytearray()
            while len(data) < 8 * 1024 * 1024:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data.extend(chunk)
                if b"\n" in chunk:
                    break
        try:
            reply = json.loads(data)
        except (ValueError, UnicodeDecodeError) as exc:
            raise BridgeError("invalid bridge reply") from exc
        if not isinstance(reply, dict) or not reply.get("ok"):
            raise BridgeError(str(reply.get("error", "bridge failure")))
        return reply

    def observe(self, *, ui: bool = True, ocr: bool = False, screenshot: bool = False) -> dict[str, Any]:
        return self.request({"op": "observe", "ui": ui, "ocr": ocr, "screenshot": screenshot})

    def act(self, observation_id: str, action: dict[str, Any]) -> dict[str, Any]:
        return self.request({"op": "act", "observation_id": observation_id, **action})


class SSHBridgeClient(BridgeClient):
    """Call the device CLI as mobile; the bridge never accepts SSHD's root UID."""

    def __init__(self, host: str, identity: Path, port: int = 22):
        self.command = ["ssh", "-i", str(identity), "-p", str(port),
                        "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
                        f"mobile@{host}"]

    def request(self, payload: dict[str, Any]) -> dict[str, Any]:
        command = "beanbaoctl " + shlex.quote(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        result = subprocess.run([*self.command, command], capture_output=True, text=True, timeout=30)
        if result.returncode:
            detail = result.stderr.strip()[:300] or result.stdout.strip()[:300]
            raise BridgeError(detail or f"device CLI exited {result.returncode}")
        try:
            reply = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise BridgeError("invalid device CLI reply") from exc
        if not isinstance(reply, dict) or not reply.get("ok"):
            raise BridgeError(str(reply.get("error", "bridge failure")))
        return reply


class Model(Protocol):
    needs_image: bool

    def next_action(self, task: str, observation: dict[str, Any], history: list[dict[str, Any]]) -> dict[str, Any]: ...


class MockModel:
    needs_image = False

    def next_action(self, task: str, observation: dict[str, Any], history: list[dict[str, Any]]) -> dict[str, Any]:
        matches = [bundle for bundle, names in ALLOWED_APPS.items() if any(name in task.lower() for name in names)]
        if len(matches) != 1:
            raise ValueError("模拟模型只支持明确的‘打开设置/备忘录/地图’任务")
        target = matches[0]
        current = observation.get("frontmost_app", {}).get("bundleId")
        if current == target:
            return {"action": "done", "summary": "目标 App 已在前台"}
        if history:
            raise ValueError("启动后仍未进入目标 App，停止重试")
        return {"action": "launch_app", "bundle_id": target}


class OpenAICompatibleModel:
    needs_image = True

    def __init__(self, base_url: str, model: str, api_key: str):
        if not base_url.startswith("https://") or not model or not api_key:
            raise ValueError("model requires HTTPS base URL, name, and API key")
        self.url = base_url.rstrip("/") + "/chat/completions"
        self.model = model
        self.api_key = api_key

    def next_action(self, task: str, observation: dict[str, Any], history: list[dict[str, Any]]) -> dict[str, Any]:
        screen = observation.get("screenshot") or {}
        state = {key: value for key, value in observation.items() if key != "screenshot"}
        prompt = {"task": task, "observation": state, "recent_actions": history[-4:]}
        content: list[dict[str, Any]] = [{"type": "text", "text": json.dumps(prompt, ensure_ascii=False)}]
        if screen.get("data"):
            content.append({"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + screen["data"]}})
        body = {"model": self.model, "temperature": 0, "messages": [
            {"role": "system", "content": "Return only one JSON object: {action: launch_app|tap|swipe|input_text|press_key|done, ...}. Never propose installs, shell, files, purchases, messages, deletion, or lock-screen actions. If uncertain, return done with summary explaining why."},
            {"role": "user", "content": content},
        ]}
        request = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers={
            "Authorization": "Bearer " + self.api_key, "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        text = result["choices"][0]["message"]["content"]
        if isinstance(text, list):
            text = "".join(part.get("text", "") for part in text if isinstance(part, dict))
        parsed = json.loads(text)
        if not isinstance(parsed, dict):
            raise ValueError("model returned a non-object")
        return parsed


@dataclass
class Policy:
    task: str
    allow_ui_actions: bool = False

    def check(self, action: dict[str, Any], observation: dict[str, Any]) -> None:
        name = action.get("action")
        if name not in ALLOWED_ACTIONS:
            raise ValueError(f"forbidden action: {name}")
        state = observation.get("device_state", {})
        if not state.get("locked_known") or state.get("locked") is not False or not state.get("screen_on_known") or state.get("screen_on") is not True:
            raise ValueError("device is locked, screen off, or lock state unknown")
        if time.time() - float(observation.get("timestamp", 0)) > 8:
            raise ValueError("observation expired")
        if name == "done":
            return
        if name in {"tap", "swipe", "input_text", "press_key"} and not self.allow_ui_actions:
            raise ValueError("UI actions require supervised test mode")
        current = observation.get("frontmost_app", {}).get("bundleId")
        named_apps = [bundle for bundle, names in ALLOWED_APPS.items()
                      if any(name in self.task.lower() for name in names)]
        if name == "launch_app":
            if action.get("bundle_id") not in ALLOWED_APPS:
                raise ValueError("app is outside allowlist")
            if len(named_apps) == 1 and action.get("bundle_id") != named_apps[0]:
                raise ValueError("app does not match the requested task")
            return
        if current not in ALLOWED_APPS:
            raise ValueError("foreground app is outside allowlist")
        if len(named_apps) == 1 and current != named_apps[0]:
            raise ValueError("foreground app does not match the requested task")
        if name in {"tap", "swipe"}:
            size = observation.get("screen", {})
            pairs = [("x", "y")] if name == "tap" else [("x1", "y1"), ("x2", "y2")]
            for xkey, ykey in pairs:
                x, y = action.get(xkey), action.get(ykey)
                if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in (x, y)):
                    raise ValueError("invalid coordinates")
                if not (0 <= x < size.get("width", 0) and 0 <= y < size.get("height", 0)):
                    raise ValueError("coordinates outside screen")
        if name == "input_text" and (not isinstance(action.get("text"), str) or not 1 <= len(action["text"]) <= 200):
            raise ValueError("invalid text length")
        if name == "press_key" and action.get("key") not in {"enter", "delete", "backspace", "space"}:
            raise ValueError("forbidden key")


def run(task: str, bridge: BridgeClient, model: Model, *, allow_ui_actions: bool = False,
        approve: Callable[[dict[str, Any]], bool] | None = None) -> str:
    history: list[dict[str, Any]] = []
    policy = Policy(task, allow_ui_actions)
    deadline = time.monotonic() + 300
    for _ in range(20):
        if time.monotonic() >= deadline:
            raise TimeoutError("task exceeded five minutes")
        observation = bridge.observe(ui=True, ocr=model.needs_image, screenshot=model.needs_image)
        if model.needs_image and contains_visible_secret({"ui": observation.get("ui"), "ocr": observation.get("ocr")}):
            raise ValueError("界面包含疑似密钥，已停止向模型发送内容")
        action = model.next_action(task, observation, history)
        policy.check(action, observation)
        if action["action"] == "done":
            return str(action.get("summary", "完成"))
        if action["action"] in {"tap", "swipe", "input_text", "press_key"}:
            if approve is None or not approve(action):
                raise ValueError("UI action was not approved")
        bridge.act(observation["observation_id"], action)
        history.append(action)
    raise TimeoutError("task exceeded 20 actions")


def main() -> int:
    parser = argparse.ArgumentParser(description="BeanBao text-first agent")
    parser.add_argument("task")
    parser.add_argument("--socket", default="/var/mobile/Library/Caches/BeanBao/bridge.sock")
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--ssh-host", help="paired device address; uses mobile SSH and beanbaoctl")
    parser.add_argument("--ssh-identity", type=Path, help="paired device private key path")
    parser.add_argument("--ssh-port", type=int, default=22)
    parser.add_argument("--model", choices=("mock", "openai"), default="mock")
    parser.add_argument("--allow-ui-actions", action="store_true", help="supervised UI testing only")
    args = parser.parse_args()
    if bool(args.ssh_host) != bool(args.ssh_identity):
        parser.error("--ssh-host and --ssh-identity must be supplied together")
    if not args.ssh_host and not args.token_file:
        parser.error("provide mobile SSH details or --token-file")
    model: Model = MockModel() if args.model == "mock" else OpenAICompatibleModel(
        os.environ.get("BEANBAO_BASE_URL", ""), os.environ.get("BEANBAO_MODEL", ""), os.environ.get("BEANBAO_API_KEY", ""))
    try:
        def approve(action: dict[str, Any]) -> bool:
            print("待执行：" + json.dumps(action, ensure_ascii=False), file=sys.stderr)
            return input("输入 yes 执行这一步：").strip() == "yes"

        bridge = (SSHBridgeClient(args.ssh_host, args.ssh_identity, args.ssh_port) if args.ssh_host else
                  BridgeClient(args.socket, args.token_file.read_text().strip()))
        result = run(args.task, bridge, model,
                     allow_ui_actions=args.allow_ui_actions, approve=approve if args.allow_ui_actions else None)
        print(result)
        return 0
    except (BridgeError, ValueError, TimeoutError, OSError, KeyError, EOFError) as exc:
        print(f"BeanBao 停止：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
