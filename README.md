# BeanBao

越狱 iPhone 上的个人 GUI 助手。当前首发目标：已连接的 iPhone 11，iOS 26.0.1，Relaxin 0.5.5。

真机当前已安装 roothide 专用 Bridge 0.1.7、原生 Agent 0.2.0 和 BeanBao App 0.2.0。已验证应用启动、AX、截图、Vision OCR、点击、输入，以及手机端模拟模型和 Claude 的打开应用任务。仓库已构建 Bridge 0.2.0 / Agent 0.3.0 / App 0.3.0 候选包，加入受限的地图搜索与新建备忘录、语音输入和音量下键三连按唤醒。候选包尚未装机；当前手机虽保持 USB 连接，Relaxin 的越狱服务与 SSH 未运行，待恢复后才能做真机验收。

- [Relaxin / iOS 26 真机落地方案](docs/relaxin-ios26-plan.md)
- [当前实现与真机验收步骤](docs/build-and-test.md)
- [首批常见任务与验收标准](docs/common-cases.md)
- [ios-mcp 上游源码快照与来源](vendor/UPSTREAM.md)
