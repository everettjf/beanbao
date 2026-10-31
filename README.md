# BeanBao

越狱 iPhone 上的个人 GUI 助手。当前首发目标：已连接的 iPhone 11，iOS 26.0.1，Relaxin 0.5.5。

真机当前安装 RootHide 专用 Bridge 0.2.4、原生 Agent 0.3.49 和 BeanBao App 0.3.12。已接入 Palmino Harness 的有界逐步执行，并保留白名单限制。模拟模式无需模型 Key，支持文字打开设置、通讯录、备忘录、地图，新建指定内容的备忘录，以及受限的地图地点搜索。Claude 地图路径仅在本地固定动作无匹配时考虑发送截图，并在每步检查前台、敏感内容和动作许可。BeanBao 不能安装第三方 App、发送消息、付款或删除内容。

当前三包组合已在解锁的真机完成文字回归：服务入口五条打开 App 指令均返回 `done` 并与实际前台一致，带“发消息”的组合指令被拒绝；BeanBao App 键盘上方的“开始”按钮实际提交并打开地图，App 文字入口还完成打开通讯录、新建唯一测试备忘录及搜索金门大桥。备忘录标题、地图标记与地点卡片均由独立观察确认；App 对禁止组合指令显示“未开始”，任务 ID 未变化。地图搜索的动态界面仍可能安全停止。实体音量键三连按、物理拔线独立运行、当前版本重启恢复及其他设备兼容性仍待验收。
- [Relaxin / iOS 26 真机落地方案](docs/relaxin-ios26-plan.md)
- [当前实现与真机验收步骤](docs/build-and-test.md)
- [安装、配置与支持范围](docs/install-and-configure.md)
- [重启后恢复与 USB 复测](docs/device-recovery.md)
- [需要真人参与的最后验收](docs/human-acceptance.md)
- [首批常见任务与验收标准](docs/common-cases.md)
- [ios-mcp 上游源码快照与来源](vendor/UPSTREAM.md)
- [PalminoHarnessKit 复用评估与迁移步骤](docs/palmino-harness-reuse.md)
- [豆包角色图标源文件](design/README.md)
