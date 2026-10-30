# BeanBao

越狱 iPhone 上的个人 GUI 助手。当前首发目标：已连接的 iPhone 11，iOS 26.0.1，Relaxin 0.5.5。

当前实现包含已安装到真机的 roothide 专用最小 bridge 0.1.6、手机端诊断命令 `beanbaoctl`，以及 Mac 上通过 mobile SSH 运行的文字指令模拟代理。真机已经验证应用启动、AX、截图、Vision OCR、点击和文字输入，并用备忘录完成一次可回退的多步任务。手机端常驻 Agent、文字图形入口、真实模型、语音与按键唤醒仍待实现。

- [Relaxin / iOS 26 真机落地方案](docs/relaxin-ios26-plan.md)
- [当前实现与真机验收步骤](docs/build-and-test.md)
- [首批常见任务与验收标准](docs/common-cases.md)
- [ios-mcp 上游源码快照与来源](vendor/UPSTREAM.md)
