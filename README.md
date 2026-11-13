# ComfyUI Pocket

使用 SwiftUI + iOS 26 Liquid Glass 的 ComfyUI 手机客户端。通过 **IP + 端口** 访问自己的电脑，内置 Tailscale；工作流和生成结果不经过应用中转服务器。代码在 Windows 编写，iOS 构建和 IPA 发布全部由 GitHub Actions 完成。

## 已实现

- IPv4 / IPv6 配对，HTTP / HTTPS；局域网直连和应用内 Tailscale。
- 工作流本地导入、导出、复制、重命名、保存和服务端目录同步。
- 手机参数面板：提示词优先，输入图片上传、模型选项、数值、布尔值、随机种子、参数收藏和拖动排序。
- 节点依赖列表；保持原始节点连接与自定义结构化输入，不猜测画布 widget 到 API 的映射。
- 提交任务、WebSocket 进度和预览、自动重连、队列取消、停止确认、最近任务和图片作品保存/分享。
- ComfyUI Pocket 插件：使用 ComfyUI 自己的 `graphToPrompt()` 导出，在本机用户目录保存，不上传到外部服务。
- Actions 的 Python/Go/Swift 测试、iOS 模拟器 UI 冒烟测试、IPA 和插件 ZIP 发布。

## 安装和连接

1. 从 [Releases](https://github.com/xbunax/comfyuipocket/releases) 下载插件 ZIP，解压成 `ComfyUI/custom_nodes/comfyui_pocket/`，重启 ComfyUI。
2. ComfyUI 需要监听手机能访问的网卡，例如 `python main.py --listen 0.0.0.0 --port 8188`。
3. 安装 iOS 26+ 客户端。`unsigned.ipa` 必须先自行签名；不能直接点击安装。`signed.ipa` 的可安装设备由证书与描述文件决定。
4. 在“连接”中填写电脑 IP 和端口。第一次允许本地网络权限。
5. 桌面 ComfyUI 打开工作流 → Pocket 侧栏 → 保存当前工作流；手机“工作台 → + → 从电脑同步”。也可直接导入 API 格式 JSON，无需插件。

同步会添加新工作流，并保留手机上已有的参数编辑。需要重新获取桌面修改时，先删除手机中的对应副本，再同步。插件的“选择覆盖”仅覆盖服务端 Pocket 目录中的条目，不修改原始 ComfyUI 工作流。

## 内置 Tailscale

手机端链接 Go `tsnet` 静态库，在应用进程内运行独立节点，不需要外部 Tailscale iOS 应用或 NetworkExtension。电脑仍需安装 Tailscale 并加入同一个 Tailnet。

打开“使用内置 Tailscale” → “启动 / 刷新 Tailscale” → 浏览器登录 → 回到应用等待 `Running`，填写电脑的 Tailscale IP。可以指定 HTTPS Headscale 控制服务器。切换控制服务器前停止组网。

**严格直连策略**：构建时对固定版本的 Tailscale 施加可审计补丁，禁用 DERP 连接，并阻止 Peer Relay 的 WireGuard 数据与握手转发。协调服务及 STUN 仍用于登录、设备发现与 NAT 打洞，它们不承载工作流或图片。直连失败会报错，不自动回退到中继。

此模式牺牲了一部分复杂 NAT 网络的可达性。iOS 后台会暂停普通应用，返回前台后重连；这不是全系统 VPN，也不保证后台常驻。查看 [网络设计](docs/NETWORKING.md)。

## GitHub Actions 与签名

`main` 的每次 push 运行检查并上传构建产物。推送 `vX.Y.Z` 标签，或在 **Build and Release → Run workflow** 输入新标签，会在所有测试通过后创建 Release。

默认没有证书时发布 `ComfyUIPocket-unsigned.ipa`。要导出签名 IPA，在仓库 Actions secrets 中配置：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | 签名证书 P12 的 Base64 |
| `IOS_CERTIFICATE_PASSWORD` | P12 密码 |
| `IOS_PROVISION_PROFILE_BASE64` | 描述文件的 Base64 |
| `IOS_KEYCHAIN_PASSWORD` | 构建临时 Keychain 密码 |

可选 Actions variables：`IOS_BUNDLE_ID`（默认 `com.xbunax.comfyuipocket`）、`IOS_SIGNING_IDENTITY`（默认 `Apple Distribution`）、`IOS_EXPORT_METHOD`（默认 `release-testing`，适用于注册设备分发）。证书、App ID、描述文件和导出方式必须匹配。不要将这些材料提交到仓库。

Release 同时包含插件 ZIP 和 SHA256 校验文件。构建失败不会发布不完整 Release。模拟器测试结果与截图保存在 `ios-test-results` artifact 的 `Tests.xcresult` 中。

## 开发

```text
ios/Pocket/              SwiftUI 界面、API 客户端、工作流模型
native/                  内置 Tailscale C ABI 与本机转发器
server/comfyui_pocket/    ComfyUI 插件和桌面导出侧栏
scripts/                 依赖准备、构建、签名、插件打包
.github/workflows/       云端构建与发布
```

Windows 可运行 Python 验证，不需要 Xcode：

```powershell
python -m pip install aiohttp
python -m unittest discover -s tests -v
python scripts/check_local_workflows.py D:\AI_video\workflows
python scripts/package_plugin.py
```

本机验证路径为 `D:\AI_video\ComfyUI`，已有启动脚本使用 8188。真实工作流和提示词不会复制进此公开仓库。

当前版本是开发预览。真实 iPhone 的组网、暂停恢复、签名安装和完整生成链路仍需设备验收。工作流编辑器编辑参数和查看依赖，不提供在手机上新增/重连节点的完整画布；自定义对象/数组输入保持原样。

## 参考与许可

交互目标参考 ComfyLink；本项目独立实现，不复制其品牌、素材或云服务协议。使用 [ComfyUI 官方 API](https://docs.comfy.org/development/comfyui-server/comms_routes)、[Apple Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)、[Tailscale tsnet](https://github.com/tailscale/tailscale/tree/main/tsnet)。本项目 MIT，Tailscale 及其依赖保留各自许可证。
