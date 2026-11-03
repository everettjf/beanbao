# BeanBao

[English](README.md) · **简体中文**

<img src="design/beanbao-icon-1024.png" alt="BeanBao：微笑的豆包" width="112" />

**一款在越狱 iPhone 上执行有边界任务的语音与文字助手。**
说出或输入需求，核对文字后让 BeanBao 操作手机。Bridge 和任务 Agent
都在手机上运行；安装完成后无需连接 Mac。

[快速安装](#快速安装) · [完整安装指南（英文）](docs/install-and-configure.md) · [目前能做什么](#目前能做什么) · [网站](web/README.md)

> **发布状态：开发者候选版。** 目前只在一台 iOS 26.0.1、Relaxin 0.5.5、
> RootHide 环境的 iPhone 11 上安装并验证。其他设备、越狱和 iOS 版本尚未验证。
> 当前公开版本是开发者预览版。准确包版本与校验值见
> [发布记录](docs/release-0.3.72.md)。

## 目前能做什么

| 需求或操作 | 当前表现 |
| --- | --- |
| “Open Settings / Maps / Contacts / Notes” | 打开指定应用，并核对它是否确实进入前台。 |
| “Create note: BeanBao test note” | 新建备忘录，并在列表中核对标题。 |
| “Search Maps for Golden Gate Bridge” | 在地图中搜索地点并核对地点卡片；必要时可把地图截图发送给所选模型。 |
| 连按三次音量下键 | 在当前应用上显示底部浮层，启动 Apple 语音转写；核对文字后再点 **Run**。快捷方式默认关闭。 |
| 调研并生成带来源的 PDF | 执行可保存进度的多步调研流程，在 **Sessions** 中打开 PDF。 |
| 调研、邮件草稿与 App Store 查找 | 准备供用户审阅的步骤；邮件发送和应用安装仍由用户在系统界面完成。 |
| 外卖 | 独立的沙盒网页 App 可在 Uber Eats 查找商品、选择选项并核对购物车；真实结账尚未验证，最终下单需要用户明确审阅和点击。 |

BeanBao 目前不提供任意应用自动点击、静默安装 App Store 应用、自动发送邮件或无人值守付款。
详见[常见需求](docs/common-cases.md)和[复杂任务边界](docs/complex-workflows.md)。

BeanBao 采用两个可见 App：**BeanBao** 负责指令、语音、Sessions 与审阅；
**BeanBao Web** 负责沙盒网页任务。当前公开版本的第二个图标仍显示“BeanBao Delivery”；
源码构建已改名，并保留原安装身份和网站数据。详见[双 App 设计（英文）](docs/two-app-architecture.md)。

## 快速安装

### 1. 检查设备

手机须已越狱，具备可用的 **RootHide** 环境、`iphoneos-arm64e` 包支持，
并能通过手机上的 root shell 或已配对的 root SSH 安装。BeanBao 不负责安装越狱环境。
当前唯一经过验证的设备组合见上方发布状态。

### 2. 下载并校验发布包

从 [GitHub Releases](https://github.com/everettjf/beanbao/releases)
下载未压缩的 `BeanBao-RootHide-*.tar`，对照发布说明中的 SHA-256：

```sh
shasum -a 256 BeanBao-RootHide-*.tar
```

当前版本的包版本和归档哈希记录在[发布记录](docs/release-0.3.72.md)。

### 3. 在手机 root shell 中安装

将校验通过的 `.tar` 传到手机，在归档所在目录执行以下命令。
把 `RELEASE.tar` 换成实际文件名：

```sh
mkdir -p beanbao-release
tar -xf RELEASE.tar -C beanbao-release
cd beanbao-release
sh install.sh --dry-run
sh install.sh
```

安装器会先检查四个包的哈希、包 ID、架构和版本，仅安装发生变化的包。
已有 root SSH 的开发者也可以使用[Mac 传输安装工具](docs/install-and-configure.md#packages)。

### 4. 激活并配置

首次安装或更新 **Bridge** 后，重载一次 SpringBoard，再手动解锁手机；
安装器不会自动重载。打开 BeanBao，在 **Model service** 卡片点击 **Change**，
填入自己的 Claude API Key 和模型名称。请勿把密钥放进聊天、截图、发布包或命令历史。
打开应用和创建备忘录可在本地完成；调研与外卖规划需要 Claude。
受限 UI 理解也可选择 OpenAI 或兼容的 HTTPS 模型服务。

在文本框输入 **Open Settings**，点击 **Start**。随后可尝试
**Create note: BeanBao test note** 或 **Search Maps for Golden Gate Bridge**。
如需音量键快捷方式，可在 BeanBao 中打开 **Quick launch**。
模型设置、语音、Sessions、恢复和外卖审阅详见[完整安装指南](docs/install-and-configure.md)。

## 从源码构建

在 macOS 上准备 Xcode、Swift、Python 3 和
[兼容 RootHide 的 Theos](https://github.com/roothide/Developer)，将 `THEOS`
设为工具链路径。构建脚本会运行原生策略、Python 和 Swift Harness 检查，
再审计并打包四个 RootHide `.deb`：

```sh
git clone https://github.com/everettjf/beanbao.git
cd beanbao
THEOS=/absolute/path/to/roothide-theos ./scripts/build_packages.sh
python3 scripts/prepare_release_bundle.py
```

生成的归档位于被 Git 忽略的 `dist/`。普通 Theos 或 rootless 包不能直接替换此
`iphoneos-arm64e` 版本。详见[构建与设备测试](docs/build-and-test.md)。

## 组成与限制

- `bridge/`：SpringBoard 中受限的屏幕观察、输入操作和语音浮层。
- `agent-native/`、`harness/`：手机端任务服务、模型客户端、策略和可恢复流程。
- `app/`：BeanBao 界面、Apple 语音转写、模型设置、Sessions 和 Activity。
- `delivery-browser/`：BeanBao Web，目前只提供受限的 Uber Eats 实验流程；源码目录保留历史名称。
- `vendor/`：保留原许可与说明的 ios-mcp、PalminoHarnessKit 源码快照。
- `scripts/`、`tests/`：构建、包审计、安装器与验收工具。
- `web/`：无需构建工具的 GitHub Pages 网站，默认英文，提供简体中文页面。

当前版本已在配对手机上通过拔掉 USB 后的文字任务、重启恢复、语音浮层、
Claude 地图搜索、多步调研和 PDF 预览。Apple Mail 编辑器尚未在已配置账号上验收；
真实外卖结账、最终下单和订单历史核对也尚未实测。其他手机的首次安装仍待验证。
本项目目前是开发者安装方式，并非一键软件源。

BeanBao 自有代码采用 [Apache-2.0](LICENSE)，版权归 2026 everettjf 所有。
第三方代码保留各自许可，见 [THIRD_PARTY.md](THIRD_PARTY.md) 和 [NOTICE](NOTICE)。
