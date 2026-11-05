# 事实来源

核对日期：2026-11-03。项目自身的代码、文档及真机验收图是本文功能与限制的主要来源。文中的“已验证”只指这一台测试设备，不推及其他 iPhone 或越狱环境。

| 文章内容 | 项目内证据 |
| --- | --- |
| 测试机、安装条件、四个 RootHide 包与 v0.3.75 发布 | `README.md`、`README.zh-CN.md`、`docs/install-and-configure.md`、`docs/release-0.3.75.md`、`docs/build-and-test.md`、公开发布归档的 SHA-256 校验记录 |
| 文字、语音、三连按浮层 | `app/main.m`、`app/LocalDictation.swift`、`bridge/BBQuickOverlay.m`、`docs/build-and-test.md`、`images/fig02-app-home.png`、`images/fig03-voice-overlay.png` |
| Bridge 的观察与操作约束 | `bridge/BeanBaoBridge.m`、`docs/quick-overlay-prototype.md` |
| Agent、Palmino、会话和多步流程 | `agent-native/AgentService.m`、`harness/`、`docs/palmino-harness-reuse.md`、`docs/complex-workflows.md` |
| PDF、邮件草稿、App Store 审核边界 | `docs/complex-workflows.md`、`docs/install-and-configure.md`、`dist/acceptance/speech-recognition-ios-current-build.pdf` |
| 外卖购物车与尚未验证的实际下单 | `docs/complex-workflows.md`、`dist/acceptance/uber-eats-cart-current-build.png` |
| 网站与简体中文 | `web/index.html`、`web/zh-CN/index.html`、`web/styles.css`、`images/fig01-website.png` |
| BeanBao Helper 名称、沙盒边界、两 App 安装与升级 | `docs/two-app-architecture.md`、`docs/release-0.3.75.md`、`design/architecture.svg`、`app/entitlements.plist`、`delivery-browser/entitlements.plist`、`agent-native/AgentClient.m`、`agent-native/AgentService.m`、`app/main.m`、`delivery-browser/Resources/Info.plist` |
| iOS App 沙盒、RootHide 的 `jbroot` 与私有签名权限 | [Apple iOS 运行时安全](https://support.apple.com/en-au/guide/security/sec15bfe098e/web)、[RootHide 权限说明](https://github.com/roothide/Developer/blob/main/entitlements.md)、[RootHide 与 rootless 的路径差异](https://github.com/roothide/Developer/blob/main/roothide.md)、[RootHide 开发者 README](https://github.com/roothide/Developer) |

对外入口（已公开）：

BeanBao 源码仓库 : https://github.com/everettjf/beanbao

BeanBao v0.3.75 安装发布页 : https://github.com/everettjf/beanbao/releases/tag/v0.3.75

BeanBao 项目网站 : https://xnu.app/beanbao/
