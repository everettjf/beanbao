# BeanBao：Relaxin / iOS 26 真机落地方案

更新：2026-10-30。本方案以当前通过 USB 连接的 iPhone 为首发目标。Bridge 0.2.0、原生 Agent 0.3.19、BeanBao App 0.3.5 已安装；逐项证据与未完成关卡见 [build-and-test.md](build-and-test.md)。安装与配置见 [install-and-configure.md](install-and-configure.md)。

通过 copyapp 的 USB iCTRL 通道重新启用 Relaxin 后，SSH 已恢复。手机端 Claude 服务已完成地图搜索和新建备忘录；App Claude 地图任务从旧结果卡片出发完成渔人码头、旧金山市政厅和金门大桥搜索。Agent 0.3.12 增加精确匹配搜索建议点击后，手机端又从旧结果卡片连续完成旧金山市政厅和加州科学院；0.3.13 再由 App 文字入口完成加州科学院。仍不能宣称任意地点可靠。电脑播报“打开地图”经手机录音、本机转写、确认后完成任务；真人语音与实体音量键三连按仍需验收。

## 1. 当前已确认的设备事实

通过 Xcode CoreDevice 的只读查询确认：

| 项目 | 结果 |
| --- | --- |
| 设备 | iPhone 11，A13，arm64e，128 GB |
| 系统 | iOS 26.0.1，build 23A355 |
| 连接 | USB 有线配对，开发者模式已启用 |
| 越狱 | Relaxin 0.5.5 App 已安装；通过 USB iCTRL 重新触发 Jailbreak 后，`jailbreakd`、`hookd` 恢复运行 |
| 远程访问 | 该机专用 SSH 密钥已验证，mobile/root 均可免密登录；当前通过 USB 端口转发访问 |
| Mac 构建环境 | Xcode 27.1、ldid、Theos + iPhoneOS16.5 SDK；已找到另一套 roothide 专用 Theos 并用其成功构建 arm64e 包 |

设备端 shell 确认：/var/jb 指向 /，dpkg 与 launchctl 可用；已安装 RootHide 核心包和 ElleKit 1.2-1。BeanBao Bridge 0.1.7 的 SpringBoard 注入、AX、OCR、截图、点击和输入已经在 iOS 26 上首轮通过。文档不记录设备序列号、完整 UDID 或 SSH 地址。

此前认证失败的原因是 Mac 默认使用 ~/.ssh/id_ed25519；该机以前的 copyapp 项目使用独立的 cases/ssh/ios26_ed25519。本次通过 Fila 的 root 安装通道把这把专用密钥的**公钥**授权给 root，root SSH 已免密验证。重复连接应指定这把密钥并开启 IdentitiesOnly，优先沿用 copyapp 已验证的 USB 转发与固定主机密钥配置，避免依赖本次连接的临时 IPv6 地址。私钥不复制进 BeanBao 仓库。

[Relaxin 官方公开源码](https://github.com/owngoal-dev/Relaxin)说明其为 RootHide 架构，但该仓库是 2026-08 归档的旧快照，README 只写到 iOS 17.3.1；因此当前 iOS 26 上的具体行为以这台真机验证为准。不要套用 Dopamine 的 rootless 路径或包。

## 2. 目标与边界

目标是：用户在这台手机上打开 BeanBao，输入或说出目标；手机本地 Agent 观察并接管**已解锁的前台界面**，调用用户选择的模型服务得到下一步动作，逐步执行和验证；拔掉电脑后仍能完成白名单任务。模型推理可以在云端或局域网服务器。

“不要安装第三方的逻辑”落实为两层：

1. **BeanBao 的执行接口没有安装/卸载任意 App 或 deb 的能力。** 模型、Agent 与开发者都不能经 BeanBao 的服务上传包、运行安装器或执行 shell。
2. **构建产物不捆绑 AppSync、IPA 安装器、fakesign、setuid root helper 等为了安装第三方应用而存在的组件。** BeanBao 自身仍需作为一个受控包安装到越狱环境；这是交付方式，不是向 Agent 开放安装功能。

首版只自动操作系统设置、备忘录、地图等指定 App，且只做无金钱损失、可检查的任务。地图首次使用设置已按用户明确授权完成，文字指令启动和一次 Claude 受监督地点搜索已通过。发消息、下单、支付、转账、删除、读取任意文件与锁屏输入都不进入首版。后台进程可待命；屏幕自动操作必须占用前台，遇锁屏/用户切换 App 即暂停。

## 3. 已复制的上游源码与改造边界

仓库 [vendor/ios-mcp](../vendor/ios-mcp) 已保存 witchan/ios-mcp 的固定源码快照，commit 见 [UPSTREAM.md](../vendor/UPSTREAM.md)。其 [MIT 许可证和第三方声明](../vendor/ios-mcp/THIRD_PARTY_NOTICES.md)保留。现有上游 README 声明 roothide 仅覆盖 iOS 15–18，未宣称 iOS 26；上游 [MCPServer.m](../vendor/ios-mcp/MCPServer.m) 监听所有网卡并且无认证。BeanBao 不编译该服务，而是用 [bridge/](../bridge) 新写了受限的本地 Unix socket 服务并只链接所需的上游管理器。该最小包已在本机完成首轮真机验证。[上游 README](https://github.com/witchan/ios-mcp/blob/62c4464f688c8f269419924b1a19c996de75f175/README.md)和[服务监听源码](https://github.com/witchan/ios-mcp/blob/62c4464f688c8f269419924b1a19c996de75f175/MCPServer.m#L975-L991)可核对。

建议把这份复制继续改造成 BeanBao 专用的 bridge，而非同时依赖系统里另一份 iOS MCP；包名改为 BeanBao 自己的标识，不覆盖 com.witchan.ios-mcp，便于卸载和回滚。

### 必须删除的上游能力

| 来源 | 处理 |
| --- | --- |
| MCPServer.m 的 install_app、uninstall_app、POST /upload_file | 从工具声明、分发、HTTP 路由、实现中全部删除；未知工具/路径返回拒绝，不能只隐藏工具描述 |
| run_command、文件读写/下载、系统日志、open_url、剪贴板、杀 App、亮度/音量写入 | 首版全部删除或不编译；避免通过其他端点重新获得安装能力 |
| AppManager.m 的 IPA/deb 安装与卸载流程 | 只保留白名单 App 启动、前台查询所需的最小实现；与安装器拆成不同源码，不把大文件原封不动链接进包 |
| AppSync、AppSync/appinst、mcp-roothelper、mcp-ldid、mcp-root、mcp-logreader | 从 Makefile、build.sh、打包布局和最终 deb 中移除；用包内容审计确认不存在 |
| PaddleOCR、ONNX Runtime、OpenCV worker | 首版改用系统 Vision OCR；省掉 15 MB 以上的第三方依赖、模型文件及子进程 |
| 上游 Settings 的远程分享/二维码、默认开机监听 | 改为 BeanBao 本地开关与状态页；默认禁用网络服务 |

**保留并适配**：SpringBoard 内的屏幕信息、截图、AX/UI 树、Vision OCR、HID 点按/滑动、文字输入、前台 App 查询与白名单启动。每项在 iOS 26 上单独测，不从 iOS 18 的通过记录推断兼容。

### 通信与权限

最终 bridge 优先只接收手机本地 Agent 的受限 Unix socket 连接；为开发期 MCP 调试可保留 127.0.0.1 HTTP，但必须有随机令牌，且只开放同一组最小工具。删除监听所有网卡的 INADDR_ANY。Mac 连接时走已授权的 SSH/USB 隧道，不把 8090 暴露到 Wi-Fi。令牌仅解决调用者鉴别；动作权限仍由 Agent 的白名单/策略器约束。

## 4. 端侧系统设计

- **Bridge（上游 ios-mcp 深改）**：注入 SpringBoard，负责观察与低级输入。它不接收自然语言、不持有模型 Key、不决定是否点击。
- **beanbaod**：已有 mobile 权限原生 CLI 和由 launchd 管理的本地服务，支持模拟模型/Claude、精确任务白名单、状态与停止。受限地图搜索已完成手机端 Claude 真机任务；本地确定性备忘录流程连续完成两条测试笔记，且不向模型发送笔记界面。仍需扩大任务样本并做当前版本重启后的完整任务验收。
- **BeanBao App**：UIKit 文字入口、模型选择、状态和停止按钮已安装；App 按钮发起模拟模型“打开地图”已在真机完成。iOS 26 使用 Apple `DictationTranscriber` 在录音后本机转写，旧系统保留 `SFSpeechRecognizer` 路径。电脑中文播报的“打开地图”已从录音、转写到任务完成；真人语音以及 iOS 26 实体按键事件仍待实测。
- **模型适配器**：已接入 Claude Messages API，输入任务、当前 App、精简 UI 树/OCR 和截图；输出单个受限动作。后续可接 OpenAI 兼容的多模态服务或 AutoGLM-Phone，但不是首版验收前提。官方 [AutoGLM iOS 配置](https://github.com/zai-org/Open-AutoGLM/blob/main/docs/ios_setup/ios_setup.md)基于 Mac + WebDriverAgent，其执行代码不能直接放上手机，需做自己的动作适配。

单步循环：检查已解锁与白名单 → 采集有时间戳的 UI 树 → 不足时 OCR → 地图等模型任务在必要时截图交模型 → 解析一个动作 → 校验坐标、前台 App、观察新鲜度与禁止操作 → 执行一次 → 再观察并验证。设置 20 步和 5 分钟上限。输入失败、模型超时、屏幕变化不符即停，不连续盲点。审计只记录动作类型、目标 App、时间和结果；截图不默认持久化。

## 5. 真机开发关卡

| 关卡 | 交付物 | 通过条件 |
| --- | --- | --- |
| G0 环境核查，已完成 | 专用公钥认证、roothide 专用 Theos、arm64e 包构建与安装。官方[RootHide 开发文档](https://github.com/roothide/Developer)要求 roothide scheme。 | 本机已验证 dpkg 安装、SpringBoard 注入和 SSH 连接。 |
| G1 最小 Bridge，动作重复测试通过 | 从复制源码排除安装链及其他非必需能力；只绑定本地；设备上已安装可卸载的 0.2.0 包。 | 包内容无 AppSync、appinst、roothelper、ldid、Paddle/ONNX；设置/备忘录/地图共 30 次启动和完整观察零失败；BeanBao 界面点击 20 次、输入/退格/滑动各 10 次零失败。 |
| G2 Agent 闭环，端侧文字任务已运行 | App 按钮发起模拟任务打开地图和 Claude 地图搜索；手机端本地确定性流程连续新建两条指定内容的备忘录。设置与备忘录固定打开任务各 10 次，状态和前台均成功；Agent 0.3.12 从旧地点卡片连续完成旧金山市政厅和加州科学院搜索，0.3.13 又经 App 完成加州科学院，结果标记与卡片一致。另一次 Claude 地图任务在 Mac SSH 转发关闭期间完成，恢复后复核标记与卡片；数据线仍连接。 | 扩大不同地图界面的重复样本；拔掉 Mac 后独立完成固定任务，完整成功率 ≥80%。 |
| G3 入口与稳定，部分通过 | 服务 30 个禁止任务提交均拒绝，锁屏动作拒绝，停止生效；一次重启后重新启用 Relaxin，服务自动运行；按用户要求以 40 分钟、148 次采样结束空闲观察，PID 保持稳定。主动结束空闲 Agent 后 launchd 自动拉起，新进程完成“打开设置”；0.3.15 的状态回传固定文案，本地 0600 审计只记录时间、事件类别、目标 App、动作类型和结果，真机任务已核对。 | 当前版本重启后复测完整任务。 |
| G4 语音和快捷唤醒，部分实现 | Apple Speech 中文按钮和默认关闭的音量键 Tweak 已装机；语音授权、录音、本机中文转写和电脑播报的“打开地图→执行”通过；模拟快捷唤醒信号会打开 App 并自动录音。 | 用户真人语音、实体音量键三连按、拔线后的无电脑体验与普通音量行为仍待验收。 |

G1 的首轮功能、观察和基础动作重复测试已经通过；动态界面变化与异常恢复仍需持续记录。若后续截图、AX 或 HID 连续不稳定，先修 bridge 或缩小支持范围，不把模型误点当成模型问题。端侧文字 MVP 的工期须由重复测试结果校准；语音/按键另计。

## 6. 模型要求与当前缺口

Claude Sonnet 5.5 已通过 Mac 代理的真实地图截图与受监督地点搜索测试；手机端原生适配器也已直接调用成功。两端均使用原生 Messages API、图片输入和 JSON schema。G2 仍需扩大不同地图状态下的端侧重复样本。其他候选只需支持**图片 + 文字输入、返回文本**的 HTTPS 模型端点；若选择 AutoGLM，需按其动作语法编写解析器。Key 不写进仓库或日志，当前在设备本地以 mobile 所有、600 权限的单独文件配置；App 已有本机配置入口。已有的截图授权不代表所有画面适合外传；遇疑似凭据时暂停外部模型请求。

当前环境工作已完成：专用 SSH 公钥、RootHide 专用 Theos、最小包构建/审计/安装、30 次观察稳定性测试、动作重复测试、App Claude 地图多轮任务、Agent 地图精确建议复测、守护进程异常恢复与去敏审计，以及设置/备忘录各 10 次固定文字任务。下一工程任务是扩大地图动态界面的重复样本，然后做拔线、重启后的完整任务以及真人语音和实体按键验证。
