# BeanBao：Relaxin / iOS 26 真机落地方案

更新：2026-10-30。本方案以当前通过 USB 连接的 iPhone 为首发目标。最小 bridge 0.1.6 已安装、注入并完成首轮真机烟测；逐项证据与未完成关卡见 [build-and-test.md](build-and-test.md)。

## 1. 当前已确认的设备事实

通过 Xcode CoreDevice 的只读查询确认：

| 项目 | 结果 |
| --- | --- |
| 设备 | iPhone 11，A13，arm64e，128 GB |
| 系统 | iOS 26.0.1，build 23A355 |
| 连接 | USB 有线配对，开发者模式已启用 |
| 越狱 | Relaxin 0.5.5 App 已安装；当前进程列表可见 jailbreakd、hookd、Relaxin 和 Sileo，说明此次启动的越狱环境正在运行 |
| 远程访问 | 已找到该机专用 SSH 密钥，mobile 免密登录成功；USB 转发路线也用固定主机密钥验证，并核对了设备标识 |
| Mac 构建环境 | Xcode 27.1、ldid、Theos + iPhoneOS16.5 SDK；已找到另一套 roothide 专用 Theos 并用其成功构建 arm64e 包 |

设备端 shell 确认：/var/jb 指向 /，dpkg 与 launchctl 可用；已安装 RootHide 核心包和 ElleKit 1.2-1。BeanBao 0.1.6 的 SpringBoard 注入、AX、OCR、截图、点击和输入已经在 iOS 26 上首轮通过。文档不记录设备序列号、完整 UDID 或 SSH 地址。

此前认证失败的原因是 Mac 默认使用 ~/.ssh/id_ed25519；该机以前的 copyapp 项目使用独立的 cases/ssh/ios26_ed25519。本次通过 Fila 的 root 安装通道把这把专用密钥的**公钥**授权给 root，root SSH 已免密验证。重复连接应指定这把密钥并开启 IdentitiesOnly，优先沿用 copyapp 已验证的 USB 转发与固定主机密钥配置，避免依赖本次连接的临时 IPv6 地址。私钥不复制进 BeanBao 仓库。

[Relaxin 官方公开源码](https://github.com/owngoal-dev/Relaxin)说明其为 RootHide 架构，但该仓库是 2026-08 归档的旧快照，README 只写到 iOS 17.3.1；因此当前 iOS 26 上的具体行为以这台真机验证为准。不要套用 Dopamine 的 rootless 路径或包。

## 2. 目标与边界

目标是：用户在这台手机上打开 BeanBao，输入或说出目标；手机本地 Agent 观察并接管**已解锁的前台界面**，调用用户选择的模型服务得到下一步动作，逐步执行和验证；拔掉电脑后仍能完成白名单任务。模型推理可以在云端或局域网服务器。

“不要安装第三方的逻辑”落实为两层：

1. **BeanBao 的执行接口没有安装/卸载任意 App 或 deb 的能力。** 模型、Agent 与开发者都不能经 BeanBao 的服务上传包、运行安装器或执行 shell。
2. **构建产物不捆绑 AppSync、IPA 安装器、fakesign、setuid root helper 等为了安装第三方应用而存在的组件。** BeanBao 自身仍需作为一个受控包安装到越狱环境；这是交付方式，不是向 Agent 开放安装功能。

首版只自动操作系统设置、备忘录、地图等指定 App，且只做无金钱损失、可检查的任务。地图首次使用设置已按用户明确授权完成，文字指令启动已通过；地点搜索仍待验收。发消息、下单、支付、转账、删除、读取任意文件与锁屏输入都不进入首版。后台进程可待命；屏幕自动操作必须占用前台，遇锁屏/用户切换 App 即暂停。

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
- **beanbaod**：以 mobile 权限运行的本地进程；读取任务、调模型、解析严格动作 JSON、执行前校验、执行后观察、超时/取消/审计。由 Relaxin 的 launchd 环境管理，实际 service 布局在真机上验证。不要靠 SpringBoard 反复拉起。
- **BeanBao App**：最初只做文字入口、当前任务状态和停止按钮；语音通过 Apple Speech 或单独 ASR 接入，在设备与中文语言组合上验证离线能力后决定。按键唤醒和悬浮窗最后做，避免抢先引入 iOS 26 私有 API 风险。
- **模型适配器**：接口输入为任务、当前 App、精简 UI 树/OCR，必要时加一张截图；输出只能是单个受限动作。先支持一种 OpenAI 兼容的多模态服务。AutoGLM-Phone 是第一候选，UI-TARS 作为离线对照；官方 [AutoGLM iOS 配置](https://github.com/zai-org/Open-AutoGLM/blob/main/docs/ios_setup/ios_setup.md)基于 Mac + WebDriverAgent，其执行代码不能直接放上手机，需做自己的动作适配。

单步循环：检查已解锁与白名单 → 采集有时间戳的 UI 树 → 不足时 OCR → 再不足时截图交模型 → 解析一个动作 → 校验坐标、前台 App、观察新鲜度与禁止操作 → 执行一次 → 再观察并验证。设置 20 步和 5 分钟上限。输入失败、模型超时、屏幕变化不符即停，不连续盲点。审计只记录动作类型、目标 App、时间和结果；截图不默认持久化。

## 5. 真机开发关卡

| 关卡 | 交付物 | 通过条件 |
| --- | --- | --- |
| G0 环境核查，已完成 | 专用公钥认证、roothide 专用 Theos、arm64e 包构建与安装。官方[RootHide 开发文档](https://github.com/roothide/Developer)要求 roothide scheme。 | 本机已验证 dpkg 安装、SpringBoard 注入和 SSH 连接。 |
| G1 最小 Bridge，首轮烟测已通过 | 从复制源码排除安装链及其他非必需能力；只绑定本地；设备上已安装可卸载的 0.1.6 包。 | 包内容无 AppSync、appinst、roothelper、ldid、Paddle/ONNX；AX、截图、Vision OCR、点击、输入、启动均有真机成功记录。仍需各项 10 次重复和异常记录。 |
| G2 Agent 闭环，Mac 模拟代理已通过 | Mac 已用同一动作协议完成文字启动与备忘录多步任务；地图文字启动也已真机通过。下一步将 beanbaod 放到手机，模型接一个候选即可。 | 拔掉 Mac 后，设置/备忘录固定任务各跑 10 次，完整任务成功率 ≥80%；地图地点搜索需单独验收。 |
| G3 入口与稳定，约 4–7 天 | BeanBao App 文字入口、状态/停止、去敏日志、重启恢复。 | 30 个禁止操作用例 0 次被执行；连续 1 小时无失控循环；重启、重新启用 Relaxin 后可恢复。 |
| G4 语音和快捷唤醒，另估 | 本地语音可用则接 Speech；否则用户选 ASR 服务。再评估按键 Tweak。 | 无电脑完成“唤醒/输入→执行→确认结果”；权限拒绝时文字入口仍可用。 |

G1 的首轮功能烟测已经通过，稳定性数据还不足。若后续截图、AX 或 HID 连续不稳定，先修 bridge 或缩小支持范围，不把模型误点当成模型问题。端侧文字 MVP 的工期须由重复测试结果校准；语音/按键另计。

## 6. 模型要求与当前缺口

现在无需先找模型或提供 Key；当前模拟模型已经跑通文字与真机动作闭环。G2 时需要一个支持**图片 + 文字输入、返回文本**的 HTTPS 模型端点，最好兼容 OpenAI chat completions；提供模型名称、base URL、是否能接受 base64 图片、单次最大图片/上下文尺寸即可。Key 不写进聊天、仓库或日志，届时在设备本地安全配置。若选择 AutoGLM，需按其动作语法编写解析器；不能假设它直接输出 BeanBao JSON。先用允许采集的测试界面离线评估动作准确率和延迟，再决定是否自部署或换模型。已有的截图授权不代表所有画面适合外传；遇疑似凭据时暂停外部模型请求。

当前环境工作已完成：专用 SSH 公钥、roothide 专用 Theos、最小包构建/审计/安装和首轮真机烟测。下一工程任务是重复稳定性验收与手机端常驻 Agent/文字入口；语音和按键唤醒放在其后。
