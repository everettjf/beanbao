# BeanBao

越狱 iPhone 上的个人 GUI 助手。当前首发目标：已连接的 iPhone 11，iOS 26.0.1，Relaxin 0.5.5。

真机已安装 RootHide 专用 Bridge 0.2.2、原生 Agent 0.3.34 和 BeanBao App 0.3.7。已验证 App 模拟模型打开地图、Claude 地图搜索、手机端多次新建指定内容的备忘录、30 条禁止任务拦截；基础动作重复测试和设置/备忘录各 10 次固定任务均通过。Agent 在地图建议中选择精确匹配地点，从旧地点卡片连续完成旧金山市政厅和加州科学院搜索；0.3.13 又由 App 文字入口完成加州科学院，独立观察确认结果标记与卡片一致。新建备忘录使用本地确定性动作，不向模型发送备忘录列表或截图。现在可选“模拟模型”，无需配置 Key；只有返回备忘录列表并看到完整新标题才报告完成，真机通过命令行与 App 按钮两条入口验证。0.3.15 的去敏状态与本地审计记录已真机验证，launchd 在服务退出后自动拉起并完成新任务。另一次 Claude 地图任务在 Mac 的 SSH 转发关闭期间完成，恢复连接后复核结果；数据线仍连接。电脑中文播报及持机者真人发声均经手机本机转写、App 确认后完成“打开地图”；真人语音复测的 Agent 状态为 `done`，独立观察为地图前台。Agent 空闲观察 40 分钟稳定。新增 Alcatraz Island、Coit Tower、Ferry Building、Exploratorium、Palace of Fine Arts、Pier 39、Japanese Tea Garden 等地图状态已完成受限搜索；不能据此推断任意地点都可靠。运行时防自动锁屏租约已装机，锁屏拒绝与释放已验证；持续亮屏及结束后恢复仍待解锁真机测试。实体音量键三连按、拔线独立运行及其他设备兼容性仍待验收。

本机另已生成 Bridge 0.2.3 / Agent 0.3.44 / App 0.3.10 候选包：引入 PalminoHarnessKit 的 `AgentRuntime` 和 `AgentTools` 逐步处理固定打开 App、新建备忘录和地图搜索文字指令，并加入豆包角色图标。模拟模式下这三类任务均不需要模型 Key，地图步骤也不采集截图；Claude 地图搜索只在本地固定动作无匹配时考虑采集截图，发送模型前再次检查前台和敏感界面，动作仍经本地策略和新鲜界面复核。输入地点后会有限重观测，确认文字出现再继续。Bridge 使用单调时间判断观察过期，避免系统校时影响动作授权。任务状态带服务和任务 ID，避免旧任务结果覆盖新任务。候选包尚未装机验收。

- [Relaxin / iOS 26 真机落地方案](docs/relaxin-ios26-plan.md)
- [当前实现与真机验收步骤](docs/build-and-test.md)
- [安装、配置与支持范围](docs/install-and-configure.md)
- [重启后恢复与 USB 复测](docs/device-recovery.md)
- [需要真人参与的最后验收](docs/human-acceptance.md)
- [首批常见任务与验收标准](docs/common-cases.md)
- [ios-mcp 上游源码快照与来源](vendor/UPSTREAM.md)
- [PalminoHarnessKit 复用评估与迁移步骤](docs/palmino-harness-reuse.md)
- [豆包角色图标源文件](design/README.md)
