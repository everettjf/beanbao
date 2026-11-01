# BeanBao

越狱 iPhone 上的个人 GUI 助手。当前首发目标：已连接的 iPhone 11，iOS 26.0.1，Relaxin 0.5.5。

当前设备已安装 RootHide 专用 Bridge 0.2.4、Agent 0.3.50 和 App 0.3.13。已接入 Palmino Harness 的有界逐步执行，并保留白名单限制。新版移除模拟模型入口；固定打开 App 和新建备忘录仍在本机执行，地图搜索使用 Claude 并需要 Key。模型路径只在本地固定动作无匹配时考虑发送截图，每步检查前台、敏感内容和动作许可。BeanBao 不能安装第三方 App、发送消息、付款或删除内容。

已安装的三包组合在解锁真机完成文字回归：五条打开 App 指令、App 文字入口的新建测试备忘录与金门大桥搜索均通过，禁止组合指令被拒绝。持机者物理拔下 USB 后从 App 执行“打开设置”成功；接回后，新任务 ID、开始/完成审计和设置前台均得到核对。新版单一 Claude 入口已通过 App 文字任务回归；实体按键自动录音、当前版本重启恢复及其他设备兼容性仍待验收。
- [Relaxin / iOS 26 真机落地方案](docs/relaxin-ios26-plan.md)
- [当前实现与真机验收步骤](docs/build-and-test.md)
- [安装、配置与支持范围](docs/install-and-configure.md)
- [重启后恢复与 USB 复测](docs/device-recovery.md)
- [需要真人参与的最后验收](docs/human-acceptance.md)
- [首批常见任务与验收标准](docs/common-cases.md)
- [ios-mcp 上游源码快照与来源](vendor/UPSTREAM.md)
- [PalminoHarnessKit 复用评估与迁移步骤](docs/palmino-harness-reuse.md)
- [豆包角色图标源文件](design/README.md)
