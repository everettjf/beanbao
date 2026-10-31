# PalminoHarnessKit 用于 BeanBao 的可行性评估

评估日期：2026-10-30。源码基线：`/Users/xnu/products/appstore/palmino` 的 `8a70981`、PalminoHarnessKit `v2.0.0`；BeanBao 当前为 Bridge 0.2.2 / Agent 0.3.34 / App 0.3.7。本次只检查和编译本地源码，没有操作 iPhone。

## 结论

**可复用 harness 核心，不能直接用整个 PalminoHarnessKit 替换 BeanBao Agent。** 首选复用 `AgentRuntime` 与 `AgentTools` 的公开 API 和源码，继续由 BeanBao 的 SpringBoard Bridge 执行设备观察与动作。Palmino 的 SwiftUI、iSH/Linux Guest、Apple 数据 API 和 MCP 连接器不是当前 GUI 自动化闭环的必需部分。

| 模块 | 可用性 | BeanBao 的接法 |
| --- | --- | --- |
| `AgentRuntime` | 可直接复用 Swift 源码/API | 负责有界多步循环、取消、重复调用限制、超时、checkpoint 和状态快照 |
| `AgentTools` | 已复用 Swift 源码/API | 当前注册 `open_app`；后续可接 `observe` / `act` 工具，设备安全校验仍由 Bridge 和 BeanBao 适配层执行 |
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
- `harness/TextHarness.swift` 已用上游 `PHKAgentRuntime` 和 `PHKToolRegistry` 执行四个固定打开 App 文字指令。Agent 0.3.38 让这四条指令在“模拟模型”和 Claude 模式下都进入本地 harness，不向模型发送截图，也不需要 Claude Key；地图搜索和本地新建备忘录仍沿用原有受限流程。
- Mac 假 Bridge 测试 6 项通过：四个白名单指令完成、未知指令不动作、锁屏不动作、Bridge 拒绝不报成功、启动后未在前台不报成功、错误 Bundle ID 和多余参数不动作。原生策略测试和 8 项 Python 测试通过。
- Agent 0.3.36 / App 0.3.9 给每次任务和服务实例分配 ID；App 丢弃旧轮询回复，拒绝把其他任务的完成状态显示为当前任务成功，停止请求也带任务 ID。本地原生策略测试及三包构建通过。
- **尚未装机或在真机验证新 harness 路径。** 图标和 harness 候选包仅在本机生成；用户休息期间不操作手机。

## 后续迁移路径

1. **扩展设备工具。** 当前已引入 `AgentRuntime` 和 `AgentTools`，并用 `PHKToolRegistry` 注册 `open_app`。下一步基于现有 Bridge 加入受限 `observe` / `act` 工具，保持来源锁定，不复制 Palmino App 或 Linux Guest。
2. **桥接设备工具。** Swift 适配器通过现有本机 Unix socket 调用 Bridge 的 `observe`、`act`、`wake_lease`。`act` 每次都要带上刚获取的 `observation_id`；执行前检查解锁、前台 App、时间戳和任务白名单，Bridge 继续做最终拒绝。所有 GUI 工具设为串行；一次模型响应中多个动作不能绕过“观察一次、执行一步”。
3. **桥接模型。** 确定性模型替身已证明打开 App 工具调用和完成路径。后续为现有 Claude Messages 接口写适配器，将其工具调用映射到 `ModelEvent`；现有 `BBClaudeAction` 的 JSON action 格式不能直接喂给 `AgentRuntime` 的工具循环。无需向用户索取新模型。
4. **保留现有安全策略。** 地图搜索和新建备忘录的限定步骤、敏感内容本地拦截、完成条件和 wake lease 仍由 BeanBao 适配层负责。Palmino 的通用工具治理不表达这些具体屏幕条件。
5. **真机验收状态协议。** 新入口已接入同一个 `beanbaod` 及 `AgentService`，每次 `start` 返回唯一任务 ID；App 只把同一服务、同一任务的状态视为当前结果。仍需在用户方便时验证新旧任务交错和服务重启；旧实现保留为可回退版本，直到相同用例全部通过。

首期验收：离线测试四个打开 App 指令、地图搜索、新建备忘录、锁屏拒绝、过期 observation 拒绝、取消、重启后未确认动作不重放；随后在用户方便时用当前设备验证。此次评估不代表新 harness 已装机或真机兼容。
