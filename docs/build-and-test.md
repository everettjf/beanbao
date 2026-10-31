# BeanBao 真机实现与验收记录

更新：2026-10-30。目标设备：iPhone 11、iOS 26.0.1、Relaxin 0.5.5 / RootHide。以下记录来自这台已连接的真机。后半部分保留首次装机时的历史数据；当前状态以本节为准。

## 最新状态（2026-10-30）

真机当前安装 `dev.beanbao.bridge` **0.2.0**、`dev.beanbao.agent` **0.3.12** 和 `dev.beanbao.app` **0.3.5**。通过已配对的 USB iCTRL 通道重新触发 Relaxin Jailbreak，mobile/root SSH 恢复。此前一次设备重启后，已安装包保留，Agent 服务自动运行；当前版本尚未再做重启后的完整任务复测。RootHide 的 SSH shell 与 App/launchd 使用不同的 `/var/mobile` 视图，客户端已加入 socket 路径回退。

真机 App 点击“开始”已用模拟模型完成“打开地图”，也用 Claude 完成地图搜索。Agent 0.3.10 从旧地点卡片出发，App 连续完成“渔人码头”“旧金山市政厅”；0.3.11 收紧地图完成判据后，App 完成“金门大桥”，iCTRL 独立看见 Golden Gate Bridge 地图标记和详情卡片，未启动导航。0.3.11 曾在“加州科学院”动态搜索状态下拒绝模型的 `done`，避免把旧 CA-1 S 卡片误报为成功。手动复现发现输入后搜索建议中有准确的 California Academy of Sciences；点击该建议会显示正确地点。Agent 0.3.12 只在 AX 确认精确匹配建议、搜索框含原样查询且 OCR 确认建议文字的位置时允许点击。手机端 Claude 在新版本先从已打开的搜索建议完成加州科学院，随后从旧卡片依次搜索旧金山市政厅、加州科学院，三次服务状态均为 `done`；最后一次独立观察看到加州科学院标记和详情卡片，未启动导航。任意地点的稳定成功率尚未证明。手机端 Claude 服务此前也完成一次金门大桥搜索和一次“新建备忘录：BeanBao 测试 2026-10-30”，备忘录正文可见且 Done 已点击。备忘录列表中有疑似密钥形态的旧内容时，Agent 在网络请求前停止；测试改从安全的测试笔记进入，没有记录旧笔记文字。30 条禁止任务在服务入口全部拒绝，重复运行结果一致。8 个 Python 单元测试与原生地图/备忘录策略测试通过。

Bridge 在 BeanBao 自身界面完成 10 轮动作稳定性测试：点击 20/20、输入 10/10、退格 10/10、滑动 10/10，前台未意外切换。手机端模拟模型“打开设置”和“打开备忘录”各运行 10 次，服务状态和前台 Bundle ID 均成功（20/20）。这些测试由 Mac 经 USB 发起和观测，尚不能代替拔线验收。语音按钮的 Speech Recognition 与麦克风系统授权已允许。旧 `SFSpeechRecognizer` 在线路径返回 `kAFAssistantErrorDomain:203`；Apple 文档将其定义为一般识别失败，不能据此确定根因。iPhone 11 上 `SpeechTranscriber.isAvailable` 为 false，但 `DictationTranscriber` 支持 `zh_CN`；安装 Apple 中文听写资源后，真机离线文件探针将预录“打开地图”转写为“打开地图”。App 自 0.3.4 起改用录音后本机听写。电脑扬声器播报三条单句指令，App 界面完整识别“打开备忘录”“打开地图”，将“打开设置”识别为“打开”（2/3 完整匹配）；结果均可编辑，仍需用户真实发声和完整任务验收。30 秒上限已真机验证自动停止，转写后检查 App 容器内无残留录音文件。另用手机本地临时信号模拟快捷键触发，App 打开后自动进入录音并消费信号；此项不代表实体音量键事件已通过。

电脑中文播报一次“打开地图”经手机麦克风录音、本机转写为完全相同的可编辑文字，App 点“开始”后服务返回 `done` 且前台为地图。另一次播报混入无关英文，测试脚本因转写不匹配未提交任务。真人语音尚未测。Agent 空闲观察按用户要求在超过 40 分钟后停止：40.1 分钟检查点累计 148 次采样，PID 稳定且没有意外运行的任务；未取得完整一小时结果。

App 0.3.5 的 Claude Key 配置入口用无效测试字符串验证：界面报告已保存，文件属主 mobile、权限 600。随后只删除这份测试文件，设备原有的 Claude Key 保留且未输出到终端。已安装版本为 App 0.3.5 → Agent 0.3.12 → Bridge 0.2.0；包声明的最低依赖仍为 App → Agent 0.3.11 → Bridge 0.2.0。

**未完成**：拔线后的独立任务验收；当前版本重启后完整任务复测；真人发声的语音任务；实体音量键三连按与普通音量行为；地图动态界面的更大样本和失败恢复。当前不能宣称 G1–G4 全部通过。一次 Frida 客户端连接报协议错误，随后设备重启，因果关系未确认；本轮后续不依赖 Frida。

## 首次装机记录（历史快照）

### 当时已安装的实现

- `dev.beanbao.bridge` **0.1.7** 已安装并在 SpringBoard 中运行。仅编译复制的 ios-mcp 的 HID、Screen、AX、TextInput、Vision OCR 相关源码；上游 MCPServer、AppManager、安装器、shell、文件路由、Paddle/ONNX 均未编译。0.1.7 允许在 BeanBao 自身前台验证输入界面，但启动 App 的白名单仍只含设置、备忘录、地图。
- SpringBoard 只监听宿主 `/var/mobile/Library/Caches/BeanBao/bridge.sock`。普通 RootHide SSH shell 通过 `/rootfs/private/var/mobile/Library/Caches/BeanBao` 查看。目录权限 700，socket 和随机 token 权限 600；仅接受 UID 501 的本地进程与正确 token。没有 TCP/HTTP 监听。
- `observe` 支持锁屏/亮屏、前台 App、屏幕尺寸以及可选 AX、Vision OCR、截图。`act` 只支持白名单 App 启动、点击、滑动、输入文本和少数按键；一次观察仅授权一步，10 秒过期，锁屏拒绝动作。
- `beanbaoctl` 是手机端受限客户端；Mac 上的 `agent/beanbao.py` 通过已认证的 mobile SSH 调用它。模拟模型只处理“打开设置/备忘录/地图”；现已接入 Claude 原生 Messages API，并用 Sonnet 5.5 做真机受监督测试。Claude 输出使用 JSON schema 约束，动作仍经过本地策略检查和逐步批准。发送模型前会检查 AX/OCR 中可见的常见密钥形态并停止该步。
- `dev.beanbao.agent` **0.2.0** 已安装。手机端原生 `beanbaod` 包含模拟模型和 Claude Sonnet 5.5 适配器；launchd 以 mobile 身份守护 `--serve`，本地 0600 Unix socket 只接受 mobile UID。服务仅接收三条精确的“打开设置/备忘录/地图”任务，提供状态与停止；每项任务由独立子进程运行。模型 Key 以 mobile 所有、权限 600 的单独文件保存在设备上，不进入 deb 或仓库。RootHide SSH shell 中该文件位于 `/rootfs/private/var/mobile/Library/Caches/BeanBao/claude.key`，Agent 进程内使用 `/var/mobile/Library/Caches/BeanBao/claude.key`。
- `dev.beanbao.app` **0.2.0** 已安装。UIKit 界面含文字输入、模型选择、开始/停止和任务状态；AX 已确认界面元素与服务状态可见。语音输入按钮已编译安装，优先使用本机中文识别，设备不支持时由 Apple Speech 在线识别；首次授权和实际转写尚待解锁后验收。界面点击“开始/停止”的端到端验收同样待解锁。
- 仓库另已构建 **Bridge 0.2.0 / Agent 0.3.0 / App 0.3.0 候选包**，尚未装机。Bridge 增加默认关闭的音量下键三连按唤醒；唤醒请求会打开 App 并进入语音输入，普通音量操作仍调用系统实现。App 增加按键开关、清空输入和本机更新 Claude Key 的界面；识别、授权等提示与服务状态分开显示，避免状态轮询覆盖。新 Key 存在不会被系统当缓存清理的 `Library/Application Support/BeanBao` 中，Agent 对现有缓存目录 Key 保持兼容。Agent 增加受限的“在地图搜索地点”和“新建备忘录：指定内容”多步任务：前者只允许搜索框、原样地点输入与提交搜索；后者只允许新建按钮、原样内容输入与完成按钮。语音识别常见的句末标点会在普通任务白名单校验前去掉，备忘录正文保留原文。按键钩子参考开源 [RemoteCompanion 的 `SBVolumeHardwareButtonActions` 实现](https://github.com/saihgupr/RemoteCompanion/blob/0e75074/Tweak/Tweak.x)，但该设备上的方法存在性、实际按键事件和多步任务流程尚未验证；候选包不能视为 G2/G4 通过。
- 为配置 root 公钥认证，另安装 `dev.beanbao.device-key` **0.1.1**。它只将 copyapp 已有的专用公钥加入 `/var/root/.ssh/authorized_keys`；私钥留在 Mac。清除此包时只移除这条公钥。BeanBao 运行时协议没有 root、安装器或 shell 能力。

### 当时的复现命令

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

### 当时的真机结果

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

### 当时记录的下一步验收（已被文首最新状态更新）

1. 补齐点击、滑动、输入与锁屏拒绝的重复测试，并复核异常恢复。
2. 解锁后通过界面点击“开始/停止”验证文字闭环、语音权限和转写；拔掉 Mac 后完成固定任务验收。
3. 扩展受限动作策略与多步常见任务，完成一小时运行、重启和重新启用 Relaxin 后的恢复测试。备忘录等可能显示凭据，OCR 密钥检查只是保护层，敏感界面应默认不外传。
4. 恢复 Relaxin/SSH 后依次安装 Bridge 0.2.0、Agent 0.3.0 和 App 0.3.0；确认地图搜索、三连按唤醒且不误触发，普通音量键行为正常。
