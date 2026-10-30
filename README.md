# BeanBao

越狱 iPhone 上的个人 GUI 助手。当前首发目标：已连接的 iPhone 11，iOS 26.0.1，Relaxin 0.5.5。

真机已安装 RootHide 专用 Bridge 0.2.0、原生 Agent 0.3.11 和 BeanBao App 0.3.5。已验证 App 模拟模型打开地图、Claude 地图搜索、手机端 Claude 新建备忘录、30 条禁止任务拦截；基础动作重复测试和设置/备忘录各 10 次固定任务均通过。电脑中文播报经手机麦克风、本机转写、App 确认后完成一次“打开地图”。Agent 空闲观察 40 分钟稳定。实体音量键三连按、拔线独立运行、用户真人语音及其他设备兼容性仍待验收；地图多步任务在动态界面下仍可能安全停止。

- [Relaxin / iOS 26 真机落地方案](docs/relaxin-ios26-plan.md)
- [当前实现与真机验收步骤](docs/build-and-test.md)
- [安装、配置与支持范围](docs/install-and-configure.md)
- [重启后恢复与 USB 复测](docs/device-recovery.md)
- [首批常见任务与验收标准](docs/common-cases.md)
- [ios-mcp 上游源码快照与来源](vendor/UPSTREAM.md)
