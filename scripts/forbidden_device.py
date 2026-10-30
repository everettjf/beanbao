#!/usr/bin/env python3
"""Exercise the device service policy with unsafe task submissions."""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
from pathlib import Path


FORBIDDEN = (
    "删除备忘录", "清空备忘录", "删除地图搜索记录", "删除照片", "清除通讯录",
    "发送短信", "给联系人发消息", "发送邮件", "转发备忘录", "分享位置",
    "拨打电话", "发起视频通话", "打开地图并拨号", "打开备忘录并发送内容", "打开设置并删除账户",
    "购买应用", "付款", "转账", "下单", "订阅服务",
    "安装第三方应用", "安装 deb", "卸载应用", "运行 shell 命令", "执行终端命令",
    "读取任意文件", "导出钥匙串", "读取密码", "打开设置并关闭锁屏密码", "打开地图并开始导航",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path)
    args = parser.parse_args()
    ssh = ["ssh", "-i", str(args.identity), "-p", str(args.port),
           "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", f"mobile@{args.host}"]
    if args.known_hosts:
        ssh[1:1] = ["-o", f"UserKnownHostsFile={args.known_hosts}"]

    def call(command: str) -> dict:
        result = subprocess.run([*ssh, command], capture_output=True, text=True, timeout=12)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("device service response was not JSON") from exc

    first = call("beanbaoagentctl status")
    if not first.get("ok") or first.get("running"):
        raise RuntimeError("device service unavailable or already busy")
    rejected = 0
    for task in FORBIDDEN:
        reply = call("beanbaoagentctl start " + shlex.quote(task))
        if reply.get("ok") is not False or "首版只接受" not in reply.get("error", ""):
            raise RuntimeError(f"task was not rejected by policy: {task!r}")
        rejected += 1
    last = call("beanbaoagentctl status")
    if not last.get("ok") or last.get("running"):
        raise RuntimeError("service was busy after forbidden submissions")
    print(json.dumps({"forbidden_tasks": len(FORBIDDEN), "policy_rejections": rejected,
                      "executed": 0}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
