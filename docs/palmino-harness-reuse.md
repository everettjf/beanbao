# PalminoHarnessKit 用于 BeanBao 的可行性评估

评估日期：2026-10-30；真机进展更新：2026-10-31。源码基线：`/Users/xnu/products/appstore/palmino` 的 `8a70981`、PalminoHarnessKit `v2.0.0`。初次评估只检查和编译本地源码；之后已将选定模块集成到 BeanBao Bridge 0.2.4 / Agent 0.3.49 / App 0.3.12，并完成当前版本的文字主线真机验收。

## 结论

**可复用 harness 核心，不能直接用整个 PalminoHarnessKit 替换 BeanBao Agent。** 首选复用 `AgentRuntime` 与 `AgentTools` 的公开 API 和源码，继续由 BeanBao 的 SpringBoard Bridge 执行设备观察与动作。Palmino 的 SwiftUI、iSH/Linux Guest、Apple 数据 API 和 MCP 连接器不是当前 GUI 自动化闭环的必需部分。

| 模块 | 可用性 | BeanBao 的接法 |
| --- | --- | --- |
| `AgentRuntime` | 可直接复用 Swift 源码/API | 负责有界多步循环、取消、重复调用限制、超时、checkpoint 和状态快照 |
| `AgentTools` | 已复用 Swift 源码/API | 当前注册 `open_app`、`note_step`、`map_step`；后续可拆分 `observe` / `act` 工具，设备安全校验仍由 Bridge 和 BeanBao 适配层执行 |
| `AgentProviders` | 不能直接替换当前 Claude 调用 | 现成传输是 OpenAI 兼容 `chat/completions`；BeanBao 当前调用 Anthropic `/v1/messages` 并要求 JSON action。需要实现 `ModelProvider` 适配器，或未来选用兼容模型 |
| `AgentAppleTools` | 不适合直接替换 GUI Bridge | 主要是 Contacts、Health、Maps 等 Apple API 工具合同，不提供 SpringBoard 前台切换、触控、AX 截图等越狱能力 |
| `PalminoHarnessKit` 总入口、`AgentUI`、`AgentMCP`、`AgentLinuxGuest` | 首期不用 | 总入口默认 DeepSeek 并引入额外模块；BeanBao 无需为了 harness 安装 Linux 或其他手机端服务 |

`PalminoHarnessKit` 源码是 Apache-2.0；若复制到 BeanBao 仓库，要保留它的 `LICENSE`、`NOTICE` 和来源记录。不要复制 Palmino App 或 iSH 的 GPL 代码。引用远程 Swift Package 时锁定版本；当前 Theos 构建没有 SwiftPM 依赖集成，不能仅改一行 Makefile 就链接整个包。

## 已验证的编译边界

- `swift build --package-path Packages/PalminoHarnessKit --target AgentRuntime` 通过。
- `swift test --package-path Packages/PalminoHarnessKit --filter AgentRuntimeTests`：32 项通过。
- 使用 Xcode 的 iPhoneOS 27.1 SDK，以 `arm64e-apple-ios17.0` 对 `AgentRuntime` 和 `AgentTools` 源文件分别执行 `swiftc -emit-module`：两者通过。这是源码类型检查/模块编译证明，**不是** BeanBao 的 Theos 链接、RootHide 装机或运行证明。
- 评估当日，BeanBao App 已由 Theos 编译 Swift 文件 `app/LocalDictation.swift`，但 Agent 命令行目标尚无 Swift。下方本地实施记录包含后来完成的 Agent Swift 链接、签名和 RootHide 包装结果。

## 本地实施进度

- 已复制未修改的 `AgentRuntime` 六个源文件与经过 Theos 导入适配的 `AgentTools` 六个源文件，保留 Apache 许可证、NOTICE 与来源 commit。BeanBao Agent 的 Theos 目标改为 iOS 17，`arm64e` 编译、链接、签名和 RootHide `.deb` 打包通过。
- `harness/TextHarness.swift` 已用上游 `PHKAgentRuntime` 和 `PHKToolRegistry` 执行四个固定打开 App 文字指令；“模拟模型”和 Claude 模式都进入本地 harness，不向模型发送截图，也不需要 Claude Key。
- Agent 0.3.47 的 `harness/StepHarness.swift` 统一驱动本地备忘录与地图搜索的逐步工具循环。`NoteHarness.swift` 每次只执行一个经旧策略与新鲜界面复核的动作，最多 10 次；笔记内容与 AX/OCR 界面只在本机进程中处理，不发送给远程模型。`MapHarness.swift` 最多 20 次；模拟模式由本地规则识别搜索框、输入原文、提交和核对结果，不需要模型 Key，也不采集截图。输入地点后会有限重观测，确认显示原文再继续；始终无法确认则停止。Claude 模式继续沿用现有 Messages 动作适配器；本地固定动作无匹配时才采集截图，并在发送模型前再次检查前台和敏感界面。两种地图路径的动作都经本地策略与新鲜界面复核，地点标记和详情卡片一致才报完成。工具结果只返回固定状态字段。
- Mac 假 Bridge / 步骤测试 17 项通过：固定 App 白名单、锁屏、Bridge 拒绝、前台复核，以及备忘录和地图的完成、失败、错误指令及步数上限。原生策略测试覆盖备忘录完整五步和前台变化拒绝，以及本地与模型地图的完整搜索步骤、输入文字延迟出现与始终缺失、敏感界面的本地启动、错误动作拒绝、单调时间过期判断及地点结果复核；8 项 Python 测试通过。
- Agent 0.3.36 / App 0.3.9 给每次任务和服务实例分配 ID；App 丢弃旧轮询回复，拒绝把其他任务的完成状态显示为当前任务成功，停止请求也带任务 ID。本地原生策略测试及三包构建通过。
- Bridge 0.2.4 / Agent 0.3.49 / App 0.3.12 已装机。当前版本的服务入口五条打开 App 文字指令、App 键盘上方“开始”、App 新建唯一测试备忘录、地图搜索及禁止组合指令均完成真机验收；任务 ID、服务阶段和实际前台独立核对。另一次模拟地图任务在 Mac SSH 转发关闭期间由手机端完成；新旧任务交错和 Agent 服务重启时，App 均将旧结果标为“状态未知”，新服务随后可完成新的文字任务。逐项证据见 [build-and-test.md](build-and-test.md)。

## 后续迁移路径

1. **扩展设备工具。** 当前已引入 `AgentRuntime` 和 `AgentTools`，并用 `PHKToolRegistry` 注册 `open_app`、`note_step` 和 `map_step`。后续可把单步工具进一步拆为 `observe` / `act`，但每次动作仍需经 BeanBao 的观察 ID、新鲜界面和目标 App 策略复核。保持来源锁定，不复制 Palmino App 或 Linux Guest。
2. **桥接设备工具。** Swift 适配器通过现有本机 Unix socket 调用 Bridge 的 `observe`、`act`、`wake_lease`。`act` 每次都要带上刚获取的 `observation_id`；执行前检查解锁、前台 App、时间戳和任务白名单，Bridge 继续做最终拒绝。所有 GUI 工具设为串行；一次模型响应中多个动作不能绕过“观察一次、执行一步”。
3. **桥接模型。** 固定 App、备忘录和模拟模式地图使用本地确定性模型替身。Claude 地图步骤工具内部仍调用现有 `BBClaudeAction`，再把策略结果交给运行时；这已把地图任务纳入统一步数和时限治理。若要让 Palmino 直接管理模型流与工具调用，还需为 Claude Messages 写 `ModelProvider` 适配器，把 JSON action 映射到 `ModelEvent`。无需向用户索取新模型。
4. **保留现有安全策略。** 地图搜索和新建备忘录的限定步骤、敏感内容本地拦截、完成条件和 wake lease 仍由 BeanBao 适配层负责。Palmino 的通用工具治理不表达这些具体屏幕条件。
5. **真机验收状态协议。** 新入口已接入同一个 `beanbaod` 及 `AgentService`，每次 `start` 返回唯一任务 ID；App 只把同一服务、同一任务的状态视为当前结果。当前版本已验证新任务 ID 推进、禁止组合指令不改变任务 ID、新旧任务交错与服务重启后的界面状态；完整设备重启后的任务恢复仍待验证。

首期文字控制已在当前目标设备通过；当前版本的取消、任务交错、Agent 空闲及运行中服务重启已完成真机样本，锁屏拒绝与过期 observation 拒绝也有本地或此前版本证据。完整设备重启后的任务恢复、物理拔线后的独立任务仍待验收。此机结果不代表其他设备兼容。
