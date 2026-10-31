# 真机恢复与复测

目标：这台已配对的 iPhone 11（iOS 26.0.1、Relaxin / RootHide）。重启后 BeanBao 包会保留，但越狱注入与 SSH 需要重新启用。此文不保存设备 UDID、私钥、主机密钥或模型 Key。

## 重启后恢复

1. 用 USB 连接并解锁手机，确认 Xcode CoreDevice 能看见设备。
2. 通过 copyapp 的 USB iCTRL 通道打开 `com.aapl.relaxin.P6SS9DKN6Q`，观察 Relaxin 当前页面，点 Jailbreak，等候 `jailbreakd` 与 `hookd` 恢复。不要把旧截图坐标当作固定按钮位置。
3. 用 copyapp 环境中的 `pymobiledevice3 usbmux forward <本机端口> 22 --serial <设备 UDID>` 建立 USB SSH 转发。沿用 copyapp 已配对的专用 SSH 私钥和固定 `known_hosts`，启用 `IdentitiesOnly` 与严格主机密钥检查。
4. 以 mobile 查询 `beanbaoagentctl status`，以 root 查询 `dpkg-query -W dev.beanbao.bridge dev.beanbao.agent dev.beanbao.app` 和 `launchctl print user/501/dev.beanbao.agent`。当前安装版本为 Bridge 0.2.2、Agent 0.3.34、App 0.3.7。
5. 确认手机已解锁、亮屏，然后从 BeanBao App 执行“打开设置”；复核服务状态为 `done`，前台为 `com.apple.Preferences`。Claude 地图任务应从没有疑似密钥内容的界面开始；备忘录新建任务可用模拟模式，无需 Key。

RootHide 的 SSH shell 与 App/launchd 对 `/var/mobile` 的路径视图不同。`beanbaoagentctl` 已依次尝试两种 Agent socket 路径；不要因 SSH shell 中第一个路径不可见就重复安装包。若服务未运行，先查 `launchctl print user/501/dev.beanbao.agent`，再决定是否 `launchctl kickstart -k user/501/dev.beanbao.agent`。

## USB 复测命令

以下参数使用这台设备在 copyapp 项目中的已配对文件；不要复制私钥到本仓库。

```sh
python3 scripts/verify_device.py --host 127.0.0.1 --port <本机转发端口> \
  --identity <专用私钥路径> --known-hosts <固定主机密钥文件>
python3 scripts/stability_actions.py --host 127.0.0.1 --port <本机转发端口> \
  --identity <专用私钥路径> --known-hosts <固定主机密钥文件> --rounds 10
python3 scripts/forbidden_device.py --host 127.0.0.1 --port <本机转发端口> \
  --identity <专用私钥路径> --known-hosts <固定主机密钥文件>
python3 scripts/soak_device.py --host 127.0.0.1 --port <本机转发端口> \
  --identity <专用私钥路径> --known-hosts <固定主机密钥文件> --minutes 60
```

Frida 只曾用于临时探查 SpringBoard 是否收到音量减键事件，以确定按键钩子的落点，并非 BeanBao 的运行依赖。那次客户端与服务端协议不兼容，设备随后重启，因果关系未确认；本轮不再使用 Frida。快捷键最终仍以实际音量键事件、普通音量行为和 App 录音状态为准。
