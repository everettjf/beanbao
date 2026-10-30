# BeanBao 真机实现与验收记录

更新：2026-10-30。目标设备：iPhone 11、iOS 26.0.1、Relaxin 0.5.5 / RootHide。以下记录来自这台已连接的真机。

## 已安装的实现

- `dev.beanbao.bridge` **0.1.6** 已安装并在 SpringBoard 中运行。仅编译复制的 ios-mcp 的 HID、Screen、AX、TextInput、Vision OCR 相关源码；上游 MCPServer、AppManager、安装器、shell、文件路由、Paddle/ONNX 均未编译。
- SpringBoard 只监听宿主 `/var/mobile/Library/Caches/BeanBao/bridge.sock`。普通 RootHide SSH shell 通过 `/rootfs/private/var/mobile/Library/Caches/BeanBao` 查看。目录权限 700，socket 和随机 token 权限 600；仅接受 UID 501 的本地进程与正确 token。没有 TCP/HTTP 监听。
- `observe` 支持锁屏/亮屏、前台 App、屏幕尺寸以及可选 AX、Vision OCR、截图。`act` 只支持白名单 App 启动、点击、滑动、输入文本和少数按键；一次观察仅授权一步，10 秒过期，锁屏拒绝动作。
- `beanbaoctl` 是手机端受限客户端；Mac 上的 `agent/beanbao.py` 通过已认证的 mobile SSH 调用它。模拟模型只处理“打开设置/备忘录/地图”；现已接入 Claude 原生 Messages API，并用 Sonnet 5.5 做真机受监督测试。Claude 输出使用 JSON schema 约束，动作仍经过本地策略检查和逐步批准。发送模型前会检查 AX/OCR 中可见的常见密钥形态并停止该步。
- `dev.beanbao.agent` **0.1.0** 已安装。手机端原生 `beanbaod` 当前是按需启动的文字 CLI，包含模拟模型和 Claude Sonnet 5.5 适配器；尚无常驻 launchd 服务、App 文字入口或停止按钮。模型 Key 以 mobile 所有、权限 600 的单独文件保存在设备上，不进入 deb 或仓库。RootHide SSH shell 中该文件位于 `/rootfs/private/var/mobile/Library/Caches/BeanBao/claude.key`，Agent 进程内使用 `/var/mobile/Library/Caches/BeanBao/claude.key`。
- 为配置 root 公钥认证，另安装 `dev.beanbao.device-key` **0.1.1**。它只将 copyapp 已有的专用公钥加入 `/var/root/.ssh/authorized_keys`；私钥留在 Mac。清除此包时只移除这条公钥。BeanBao 运行时协议没有 root、安装器或 shell 能力。

## 可复现命令

```sh
cd /Users/xnu/sec/beanbao/bridge
make package FINALPACKAGE=1
python3 ../scripts/audit_bridge_package.py packages/dev.beanbao.bridge_0.1.6_iphoneos-arm64e.deb
cd ..
python3 -m unittest discover -s agent -p 'test_*.py' -v
python3 scripts/verify_device.py --host '<已配对设备的 SSH 地址>' --identity '<copyapp 中该设备的专用私钥路径>'
python3 agent/beanbao.py '打开备忘录' --ssh-host '<已配对设备的 SSH 地址>' --ssh-identity '<同一私钥路径>'
python3 agent/beanbao.py '在地图搜索金门大桥，看到搜索结果后停止，不要启动导航' --model claude --allow-ui-actions --ssh-host '<已配对设备的 SSH 地址>' --ssh-identity '<同一私钥路径>'
python3 scripts/stability_device.py --rounds 10 --host '<已配对设备的 SSH 地址>' --identity '<同一私钥路径>'
cd agent-native && make package FINALPACKAGE=1
```

Mac 端 Claude 命令需要从安全的本地环境提供 `ANTHROPIC_API_KEY`，可用 `BEANBAO_CLAUDE_MODEL` 覆盖默认的 `claude-sonnet-5-5`。SSH 地址由 CoreDevice 隧道提供，可能变化。设备上的 `beanbaod '打开设置'` 可独立验证原生模拟模型；`beanbaod --claude '打开地图'` 可验证手机直接调用模型。不要把 token、私钥、模型 Key、截图或个人备忘录提交到仓库。

## 2026-10-30 真机结果

| 项目 | 结果 |
| --- | --- |
| 安装与注入 | dpkg 返回 `install ok installed 0.1.6`；SpringBoard 重载后 socket/token 创建，权限符合预期。 |
| 公钥认证 | 通过 Fila 的 root 安装通道配置现有公钥；随后 root SSH 返回 `uid=0`，无需密码。 |
| 观察 | 未解锁时报告锁定；解锁后报告前台设置/备忘录，屏幕为 414×896 点。 |
| AX / OCR / 截图 | 设置页 AX 返回 26 个元素、Vision OCR 返回 28 段文字；截图返回 JPEG 数据。 |
| 文字指令 | 手机端“打开设置”成功；Mac 模拟代理“打开备忘录”和“打开地图”成功，并复核前台 Bundle ID。 |
| UI 动作 | 在备忘录通过桥接点击“新建”、输入标记为 2026-10-30 的测试文字、点击完成；OCR 复核标题与正文可见。 |
| 动作保护 | 同一观察 ID 的第二次动作被拒绝；root UID 直接连桥接被拒绝。 |
| 地图 | 用户明确授权后，手动点“Accept & Continue”，位置选“Allow While Using App”，无线数据选“WLAN & Cellular”；通知选“Not Now”，通讯录选“Don’t Allow”。地图进入主界面并显示搜索框。返回主屏幕后，Mac 模拟代理执行“打开地图”成功；设备确认前台为 `com.apple.Maps`。 |
| Claude 模型试验 | 用户提供的临时 Key 在 Claude 官方 Models API 认证成功；Sonnet 5.5 看真实地图截图后建议点击搜索框。随后 Mac 代理用 Claude 原生 Messages API、JSON schema 和人工逐步批准完成“金门大桥”搜索；真机 AX/OCR 独立确认查询和 Golden Gate Bridge 结果可见，未启动导航。Key 没有写入仓库或设备。 |
| 受监督动作时效 | 人工批准可能超过桥接观察令牌的 10 秒期限；代理现于批准后重新观察，对照前台、屏幕尺寸和 AX（AX 不可用时用 OCR 或截图），再使用新的观察 ID 执行。地图动态位置动画不会误触发 AX 一致性检查。 |
| 稳定性首轮 | `scripts/stability_device.py --rounds 10` 循环打开设置、备忘录、地图共 30 次；30 次完整取得 AX、OCR、截图和前台状态，失败 0 次；中位 3.51 秒，最慢 5.12 秒。 |
| 手机端原生 Agent | RootHide arm64e 包构建、安装成功；手机端模拟模型完成“打开设置/地图”。手机端 Claude Sonnet 5.5 直接请求成功，完成“打开地图”。这仍是按需运行的 CLI，尚非拔线后的完整文字入口。 |

尚未完成点击、滑动、输入等每种动作的 10 次重复测试、锁屏拒绝复核、拔线后手机端常驻 Agent、重启后恢复测试。Claude 仅在手机端完成过一次打开地图，不能据此宣称 G1/G2 全部通过或已具备无人值守能力。

## 下一步验收

1. 补齐点击、滑动、输入与锁屏拒绝的重复测试，并复核异常恢复。
2. 将当前按需 CLI 接到 mobile 权限 launchd 服务和手机文字入口，加入状态、停止按钮与去敏日志；拔掉 Mac 后完成固定任务验收。
3. 扩展受限动作策略与 30 个禁止操作用例，完成一小时运行、重启和重新启用 Relaxin 后的恢复测试。备忘录等可能显示凭据，OCR 密钥检查只是保护层，敏感界面应默认不外传。
4. 文字入口稳定后再做语音和物理按键唤醒。
