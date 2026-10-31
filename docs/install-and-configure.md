# 安装、配置与支持范围

更新：2026-10-31。当前只在一台 iPhone 11、iOS 26.0.1、Relaxin 0.5.5 / RootHide 上完成真机验证。以下是开发者安装流程，不是面向普通用户的一键安装。其他型号、系统版本和越狱环境尚未验证。

## 现在能安装什么

三个 RootHide `iphoneos-arm64e` 包按顺序安装：

1. `dev.beanbao.bridge` 0.2.2：SpringBoard 中的受限观察与点击/输入桥接；固定启动白名单包含通讯录。
2. `dev.beanbao.agent` 0.3.39：手机端任务服务和 Claude 适配器，依赖 Bridge 0.2.2 以上。
3. `dev.beanbao.app` 0.3.9：文字、语音、状态与配置界面，依赖 Agent 0.3.36 以上。

本机已构建的包位于仓库的 `bridge/packages/`、`agent-native/packages/`、`app/packages/`。当前设备上已验收的仍是 Agent 0.3.34 / App 0.3.7；本机另有 Agent 0.3.39 / App 0.3.9 候选包，加入 Palmino harness 的固定打开 App 和逐步新建备忘录路径、新图标及带身份校验的任务状态协议，尚未装机验收。四条固定打开 App 指令不论模型选项都在本地执行，无需 Claude Key。需要先有可用的 Relaxin / RootHide 越狱与对应包管理环境；BeanBao 自身不提供安装任意第三方 App 的接口。当前设备通过已配对的 USB SSH 以 root 执行 `dpkg -i` 安装，其他用户可以使用其越狱环境中支持 RootHide 包的管理方式。首次安装 Bridge 后需要让 SpringBoard 重新加载，才能注入桥接；不要把安装成功等同于注入已生效。

从源码构建时，在 Mac 上准备支持 RootHide 的 Theos 工具链，并设置 `THEOS` 为其绝对路径；仓库根目录运行 `THEOS=/你的/roothide-theos ./scripts/build_packages.sh`。该脚本运行原生策略与 Python 测试、构建三个包、审计 Bridge 内容并输出 SHA-256。它只在电脑构建，不连接或修改手机；生成的 `.deb` 默认不进入 Git。

有 root shell 的开发者可将三个 `.deb` 复制到手机临时目录，依次执行：

```sh
dpkg -i dev.beanbao.bridge_0.2.2_iphoneos-arm64e.deb
dpkg -i dev.beanbao.agent_0.3.39_iphoneos-arm64e.deb
dpkg -i dev.beanbao.app_0.3.9_iphoneos-arm64e.deb
dpkg-query -W dev.beanbao.bridge dev.beanbao.agent dev.beanbao.app
```

包名和依赖请以当前构建产物的 `control` 为准。当前仓库还没有软件源、自动兼容性检查、图形安装器或面向普通用户的发布包；不能把这台手机上的成功直接推广到其他设备。

## 安装后如何配置

1. 保持手机解锁、亮屏，打开 BeanBao。先选“模拟模型”，输入“打开地图”并点“开始”；它不需要模型 Key。界面应显示完成，地图应在前台。
2. 新建测试备忘录可继续选“模拟模型”，输入“新建备忘录：测试内容”，无需 Key。Agent 会点新建、写入原文、点完成、返回列表，并核对列表里出现完整新标题才报完成；同名标题已存在时会拒绝再次创建。地图搜索才需要在 BeanBao 点“配置 Claude Key”、粘贴自己的 Anthropic Key 并选“Claude”。Key 保存在手机本地、由 mobile 用户持有的 0600 文件中，不写进包或仓库。备忘录界面不发送给模型；OpenAI API Key 尚不能直接填入此入口。
3. 点“🎙️ 语音输入”，按系统提示允许语音识别和麦克风。iOS 26 在这台设备上使用 Apple 本机中文听写；首次使用可能下载中文资源。说完点“结束录音”，先检查并编辑转写文字，再点“开始”。单次录音最长 30 秒，转写后临时音频文件会删除。
4. 音量减键三连按开关默认关闭。实现会先调用系统原有音量处理，再尝试打开 BeanBao 录音。持机者已确认三连按能打开 App，但自动开始录音曾间歇失败；App 0.3.7 改为等前台可见后再消费唤醒标记，仍待实体按键复测。其他用户暂不应把它当作可靠入口。
5. 运行中可在 BeanBao 查看状态或点“停止任务”。地图搜索只允许查看结果，不启动导航；备忘录任务只用于新建，不编辑旧内容。从其他 App 发起地图任务时，Agent 可先在本地打开地图，原界面不发给模型；目标界面若仍含疑似凭据，或遇到锁屏、不确定状态，任务会停止。任务运行时 Bridge 会尝试阻止系统自动锁屏，结束或停止后恢复先前设置；用户仍可手动锁屏。目前已验证锁屏拒绝和释放，尚待解锁后跨越系统自动锁屏时长的真机实测。

Agent 的本地审计文件位于手机的 `/var/mobile/Library/Application Support/BeanBao/audit.jsonl`，仅 mobile 可读写。它记录时间、事件类别、目标 App、动作类型和结果，不记录指令正文、地点、备忘录内容、坐标、截图、模型回复或 Key；文件超过 512 KiB 时从头重新记录。App 状态只显示固定的完成或错误类别。

## 当前能力边界

- 已验证：文字打开设置、备忘录、地图；受限 Claude 地图搜索；多次通过模拟模式新建指定内容的测试备忘录（命令行与 App 按钮均完成列表复核）；电脑中文播报和持机者真人语音均经手机录音、转写、用户确认后执行“打开地图”。
- 地图动态界面仍可能使任务安全停止。除金门大桥、渔人码头、旧金山市政厅和加州科学院外，新增 Alcatraz Island、Coit Tower、Ferry Building、Exploratorium、Palace of Fine Arts、Pier 39、Japanese Tea Garden 等真机样本；结果需由地图标记或 3D 地图标签与地点卡片共同核对，不能推断任意地点可靠。
- 尚待验收：实体音量键三连按、拔掉 USB 后的独立任务、当前版本重启后完整任务恢复，以及其他设备兼容性。
- 运行设计不依赖 Mac、iCTRL 或 Frida；Mac/iCTRL 目前只用于安装和测试。这台手机的无 USB 使用仍需实测。

故障恢复与已配对设备的复测命令见 [device-recovery.md](device-recovery.md)，逐项测试证据见 [build-and-test.md](build-and-test.md)，需要真人参与的最后验收见 [human-acceptance.md](human-acceptance.md)。
