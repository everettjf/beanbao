# BeanBao 真机实现与验收记录

更新：2026-10-30。目标设备：iPhone 11、iOS 26.0.1、Relaxin 0.5.5 / RootHide。以下记录来自这台已连接的真机。

## 已安装的实现

- `dev.beanbao.bridge` **0.1.6** 已安装并在 SpringBoard 中运行。仅编译复制的 ios-mcp 的 HID、Screen、AX、TextInput、Vision OCR 相关源码；上游 MCPServer、AppManager、安装器、shell、文件路由、Paddle/ONNX 均未编译。
- SpringBoard 只监听宿主 `/var/mobile/Library/Caches/BeanBao/bridge.sock`。普通 RootHide SSH shell 通过 `/rootfs/private/var/mobile/Library/Caches/BeanBao` 查看。目录权限 700，socket 和随机 token 权限 600；仅接受 UID 501 的本地进程与正确 token。没有 TCP/HTTP 监听。
- `observe` 支持锁屏/亮屏、前台 App、屏幕尺寸以及可选 AX、Vision OCR、截图。`act` 只支持白名单 App 启动、点击、滑动、输入文本和少数按键；一次观察仅授权一步，10 秒过期，锁屏拒绝动作。
- `beanbaoctl` 是手机端受限客户端；Mac 上的 `agent/beanbao.py` 通过已认证的 mobile SSH 调用它。模拟模型只处理“打开设置/备忘录/地图”。外部模型适配骨架尚未接实际端点；发送模型前会检查 AX/OCR 中可见的常见密钥形态并停止该步。
- 为配置 root 公钥认证，另安装 `dev.beanbao.device-key` **0.1.1**。它只将 copyapp 已有的专用公钥加入 `/var/root/.ssh/authorized_keys`；私钥留在 Mac。清除此包时只移除这条公钥。BeanBao 运行时协议没有 root、安装器或 shell 能力。

## 可复现命令

```sh
cd /Users/xnu/sec/beanbao/bridge
make package FINALPACKAGE=1
python3 ../scripts/audit_bridge_package.py packages/dev.beanbao.bridge_0.1.6_iphoneos-arm64e.deb
cd ..
python3 -m unittest discover -s agent -p 'test_*.py' -v
python3 scripts/verify_device.py --host '<已配对设备的 SSH 地址>' --identity '<copyapp 中该设备的专用私钥路径>'
python3 agent/beanbao.py '打开备忘录' --ssh-host '<已配对设备的 SSH 地址>' --ssh-identity '<同一私钥路径>'
```

SSH 地址由 CoreDevice 隧道提供，可能变化。设备上的 `beanbaoctl run '打开设置'` 可独立验证无需 Mac 模型的文字启动。不要把 token、私钥、截图或个人备忘录提交到仓库。

## 2026-10-30 真机结果

| 项目 | 结果 |
| --- | --- |
| 安装与注入 | dpkg 返回 `install ok installed 0.1.6`；SpringBoard 重载后 socket/token 创建，权限符合预期。 |
| 公钥认证 | 通过 Fila 的 root 安装通道配置现有公钥；随后 root SSH 返回 `uid=0`，无需密码。 |
| 观察 | 未解锁时报告锁定；解锁后报告前台设置/备忘录，屏幕为 414×896 点。 |
| AX / OCR / 截图 | 设置页 AX 返回 26 个元素、Vision OCR 返回 28 段文字；截图返回 JPEG 数据。 |
| 文字指令 | 手机端“打开设置”成功；Mac 模拟代理“打开备忘录”成功，并复核前台 Bundle ID。 |
| UI 动作 | 在备忘录通过桥接点击“新建”、输入标记为 2026-10-30 的测试文字、点击完成；OCR 复核标题与正文可见。 |
| 动作保护 | 同一观察 ID 的第二次动作被拒绝；root UID 直接连桥接被拒绝。 |
| 地图 | 地图应用存在，但首次使用隐私欢迎页阻止 LaunchServices 完成启动。已选择“关闭地图”，未替用户接受条款；此案例待用户自行决定首次使用设置。 |

尚未完成每种动作 10 次重复测试、拔线后手机端常驻 Agent、真实模型接入、重启后恢复测试。不能据此宣称 G1 全部通过或已具备无人值守能力。

## 下一步验收

1. 在当前设备上做 10 轮设置/备忘录的安全动作测试，记录耗时、AX 空结果、OCR 与截图失败、SpringBoard 异常；验证锁屏时动作被拒绝。
2. 将当前 Mac 代理协议迁入 mobile 权限的 `beanbaod`，配 launchd、文字入口、停止按钮和去敏日志；拔掉 Mac 后完成同样任务。
3. 接入用户提供的多模态 HTTPS 模型。模型建议仍须经过白名单、锁屏、新鲜度、坐标和危险动作策略。备忘录等可能显示凭据，OCR 密钥检查只是保护层，敏感界面应默认不外传。
4. 文字入口稳定后再做语音和物理按键唤醒。
