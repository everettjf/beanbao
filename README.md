# BeanBao

越狱 iPhone 上的个人 GUI 助手。当前首发目标：已连接的 iPhone 11，iOS 26.0.1，Relaxin 0.5.5。

真机已安装 RootHide 专用 Bridge 0.2.0、原生 Agent 0.3.8 和 BeanBao App 0.3.1。通过已配对的 USB 通道恢复 Relaxin 越狱与 SSH 后，已验证 App 按钮发起模拟模型和 Claude 地图任务、手机端 Claude 新建备忘录、30 条禁止任务拦截；点击、输入、退格、滑动重复 10 轮，以及设置、备忘录固定任务各 10 次均成功。语音授权和录音启动已通过；真实转写、音量下键三连按和拔线后的稳定性仍待验收。

- [Relaxin / iOS 26 真机落地方案](docs/relaxin-ios26-plan.md)
- [当前实现与真机验收步骤](docs/build-and-test.md)
- [重启后恢复与 USB 复测](docs/device-recovery.md)
- [首批常见任务与验收标准](docs/common-cases.md)
- [ios-mcp 上游源码快照与来源](vendor/UPSTREAM.md)
