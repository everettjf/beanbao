# BeanBao 真机实现与验收记录

更新：2026-10-30。目标设备：iPhone 11、iOS 26.0.1、Relaxin 0.5.5 / RootHide。以下记录来自这台已连接的真机。

## 已安装的实现

- `dev.beanbao.bridge` **0.1.7** 已安装并在 SpringBoard 中运行。仅编译复制的 ios-mcp 的 HID、Screen、AX、TextInput、Vision OCR 相关源码；上游 MCPServer、AppManager、安装器、shell、文件路由、Paddle/ONNX 均未编译。0.1.7 允许在 BeanBao 自身前台验证输入界面，但启动 App 的白名单仍只含设置、备忘录、地图。
- SpringBoard 只监听宿主 `/var/mobile/Library/Caches/BeanBao/bridge.sock`。普通 RootHide SSH shell 通过 `/rootfs/private/var/mobile/Library/Caches/BeanBao` 查看。目录权限 700，socket 和随机 token 权限 600；仅接受 UID 501 的本地进程与正确 token。没有 TCP/HTTP 监听。
- `observe` 支持锁屏/亮屏、前台 App、屏幕尺寸以及可选 AX、Vision OCR、截图。`act` 只支持白名单 App 启动、点击、滑动、输入文本和少数按键；一次观察仅授权一步，10 秒过期，锁屏拒绝动作。
- `beanbaoctl` 是手机端受限客户端；Mac 上的 `agent/beanbao.py` 通过已认证的 mobile SSH 调用它。模拟模型只处理“打开设置/备忘录/地图”；现已接入 Claude 原生 Messages API，并用 Sonnet 5.5 做真机受监督测试。Claude 输出使用 JSON schema 约束，动作仍经过本地策略检查和逐步批准。发送模型前会检查 AX/OCR 中可见的常见密钥形态并停止该步。
- `dev.beanbao.agent` **0.2.0** 已安装。手机端原生 `beanbaod` 包含模拟模型和 Claude Sonnet 5.5 适配器；launchd 以 mobile 身份守护 `--serve`，本地 0600 Unix socket 只接受 mobile UID。服务仅接收三条精确的“打开设置/备忘录/地图”任务，提供状态与停止；每项任务由独立子进程运行。模型 Key 以 mobile 所有、权限 600 的单独文件保存在设备上，不进入 deb 或仓库。RootHide SSH shell 中该文件位于 `/rootfs/private/var/mobile/Library/Caches/BeanBao/claude.key`，Agent 进程内使用 `/var/mobile/Library/Caches/BeanBao/claude.key`。
- `dev.beanbao.app` **0.2.0** 已安装。UIKit 界面含文字输入、模型选择、开始/停止和任务状态；AX 已确认界面元素与服务状态可见。语音输入按钮已编译安装，优先使用本机中文识别，设备不支持时由 Apple Speech 在线识别；首次授权和实际转写尚待解锁后验收。界面点击“开始/停止”的端到端验收同样待解锁。
- 仓库另已构建 **Bridge 0.2.0 / Agent 0.3.0 / App 0.3.0 候选包**，尚未装机。Bridge 增加默认关闭的音量下键三连按唤醒；App 增加开关、清空输入和本机更新 Claude Key 的界面，新 Key 存在不会被系统当缓存清理的 `Library/Application Support/BeanBao` 中，Agent 对现有缓存目录 Key 保持兼容。Agent 增加受限的“在地图搜索地点”和“新建备忘录：指定内容”多步任务：前者只允许搜索框、原样地点输入与提交搜索；后者只允许新建按钮、原样内容输入与完成按钮。语音识别常见的句末标点会在普通任务白名单校验前去掉，备忘录正文保留原文。按键钩子参考开源 [RemoteCompanion 的 `SBVolumeHardwareButtonActions` 实现](https://github.com/saihgupr/RemoteCompanion/blob/0e75074/Tweak/Tweak.x)，但该设备上的方法存在性、实际按键事件和多步任务流程尚未验证。普通音量操作仍调用原系统实现；候选包不能视为 G2/G4 通过。
- 为配置 root 公钥认证，另安装 `dev.beanbao.device-key` **0.1.1**。它只将 copyapp 已有的专用公钥加入 `/var/root/.ssh/authorized_keys`；私钥留在 Mac。清除此包时只移除这条公钥。BeanBao 运行时协议没有 root、安装器或 shell 能力。

## 可复现命令

```sh
cd /Users/xnu/sec/beanbao/bridge
make package FINALPACKAGE=1
python3 ../scripts/audit_bridge_package.py packages/dev.beanbao.bridge_0.1.7_iphoneos-arm64e.deb
cd ..
python3 -m unittest discover -s agent -p 'test_*.py' -v
sh scripts/test_native_policy.sh
python3 scripts/verify_device.py --host '<已配对设备的 SSH 地址>' --identity '<copyapp 中该设备的专用私钥路径>'
python3 agent/beanbao.py '打开备忘录' --ssh-host '<已配对设备的 SSH 地址>' --ssh-identity '<同一私钥路径>'
python3 agent/beanbao.py '在地图搜索金门大桥，看到搜索结果后停止，不要启动导航' --model claude --allow-ui-actions --ssh-host '<已配对设备的 SSH 地址>' --ssh-identity '<同一私钥路径>'
python3 scripts/stability_device.py --rounds 10 --host '<已配对设备的 SSH 地址>' --identity '<同一私钥路径>'
python3 scripts/forbidden_device.py --host '<已配对设备的 SSH 地址>' --identity '<同一私钥路径>'
python3 scripts/stability_actions.py --rounds 10 --host '<已配对设备的 SSH 地址>' --identity '<同一私钥路径>'
python3 scripts/soak_device.py --minutes 60 --host '<已配对设备的 SSH 地址>' --identity '<同一私钥路径>'
cd agent-native && make package FINALPACKAGE=1
cd ../app && make package FINALPACKAGE=1
```

Mac 端 Claude 命令需要从安全的本地环境提供 `ANTHROPIC_API_KEY`，可用 `BEANBAO_CLAUDE_MODEL` 覆盖默认的 `claude-sonnet-5-5`。SSH 地址由 CoreDevice 隧道提供，可能变化。设备上的 `beanbaod '打开设置'` 可独立验证原生模拟模型；`beanbaod --claude '打开地图'` 可验证手机直接调用模型。`beanbaoagentctl status`、`start '打开设置'`、`stop` 验证本地服务。不要把 token、私钥、模型 Key、截图或个人备忘录提交到仓库。

## 2026-10-30 真机结果

| 项目 | 结果 |
| --- | --- |
| 安装与注入 | dpkg 安装 Bridge 0.1.7、Agent 0.2.0、App 0.2.0；SpringBoard 重载后 socket/token 创建，权限符合预期。 |
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
| 手机端原生 Agent | RootHide arm64e 包构建、安装成功；手机端模拟模型完成“打开设置/地图”。手机端 Claude Sonnet 5.5 直接请求成功，完成“打开地图”。原有按需 CLI 保留供调试，现另有常驻服务。 |
| launchd 与任务服务 | `launchctl print user/501/dev.beanbao.agent` 显示 mobile 进程运行；`beanbaoagentctl` 可查询、提交和停止任务。模拟模型完成“打开设置”，Claude 完成“打开地图”。服务拒绝“删除备忘录”；30 个禁止任务提交全部由服务策略拒绝，未启动任务。实际运行中的任务被停止后状态变为 `stopped`。 |
| 手机界面 | `uicache` 注册 `dev.beanbao.app`，启动后 AX 看见文字框、模型选择、开始/停止和“已完成”状态。SpringBoard 重载后设备自动锁屏，尚未进行界面按钮点击和语音授权实测。 |
| 锁屏拒绝 | SpringBoard 重载后设备处于锁屏；服务接受“打开设置”并交给子进程后，桥接拒绝动作，服务状态变为 `error`，前台保持 SpringBoard。 |
| 当前连接 | 约 14:28 后 USB/隧道曾中断并重新分配地址。CoreDevice 后续仍可见设备，但新隧道拒绝 SSH，进程列表只见 SpringBoard 与 Relaxin，未见 sshd/jailbreakd/hookd。Device Hub 明确提示这台 iOS 26.0.1 设备不能使用其要求 iOS 27 的屏幕共享；远程启动 Relaxin App 未恢复越狱进程。需在手机上重新启用 Relaxin，恢复 SSH 后才能安装上述候选包并继续真机验收。 |

尚未完成点击、滑动、输入等每种动作的 10 次重复测试、拔线后的完整任务、重启和重新启用 Relaxin 后的恢复测试。文字界面与语音尚未在解锁状态完成点击验收；实体按键唤醒尚未实现。Claude 在手机服务中完成过一次打开地图，不能据此宣称 G1–G4 全部通过。

## 下一步验收

1. 补齐点击、滑动、输入与锁屏拒绝的重复测试，并复核异常恢复。
2. 解锁后通过界面点击“开始/停止”验证文字闭环、语音权限和转写；拔掉 Mac 后完成固定任务验收。
3. 扩展受限动作策略与多步常见任务，完成一小时运行、重启和重新启用 Relaxin 后的恢复测试。备忘录等可能显示凭据，OCR 密钥检查只是保护层，敏感界面应默认不外传。
4. 恢复 Relaxin/SSH 后依次安装 Bridge 0.2.0、Agent 0.3.0 和 App 0.3.0；确认地图搜索、三连按唤醒且不误触发，普通音量键行为正常。
