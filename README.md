# ComfyUI Pocket

使用 SwiftUI + iOS 26 Liquid Glass 的 ComfyUI 手机客户端。通过 **IP + 端口** 直连自己的电脑；外网组网使用手机上的 Tailscale 官方 App。ComfyUI 中的全部工作流会自动双向同步，不需要逐个选择。代码在 Windows 编写，iOS 构建和 IPA 发布全部由 GitHub Actions 完成。

## 已实现

- IPv4 / IPv6 配对，HTTP / HTTPS；局域网直连；外网可配合 Tailscale 官方 iOS App。
- 自动同步 ComfyUI 已保存的**全部工作流**；新增、修改、重命名、删除都会自动反映到手机。
- 手机上的参数修改、重命名和删除会自动同步回服务端 Pocket 目录，无需手动上传。
- 手机参数面板：提示词优先，输入图片上传、模型选项、数值、布尔值、随机种子、参数收藏和拖动排序。
- **批量生成**：滑块设置 1–20 次，一次提交显示为一个任务，统一查看批次进度、所有产物和每次生成的实际参数，可取消全部待执行项。后续生成可自动更换随机种子。
- **分辨率与批量设置**：同节点宽高左右并排，支持 1080p、2K QHD/DCI、4K UHD/DCI 等横竖屏组合；批量次数滑块与随机种子开关即时生效，无需确认。
- **提示词可视化编辑**：工作流内提示词输入框保留文本/分块切换，点击“编辑模式”进入独立全屏编辑页，使用大文本框或分块开关，词块紧凑排列并自动换行；点按词块设置权重、启停、分类和中英翻译，长按拖动排序或跨分类移动；保留提示词版本保存。复杂括号、LoRA、转义符与调度表达式保留。
- **提示词库与版本保存**：保存、编辑、搜索和管理常用提示词，在独立提示词编辑页中追加、替换或保存当前内容，点“应用”写回工作流。
- **工作台置顶与分组折叠**：工作流可置顶，按名称前缀分组并折叠收纳。
- **任务详情**：点开队列或历史任务，查看生成产物、实际使用的提示词和全部参数；运行中显示实时预览。
- **媒体输入预览**：图片与文件字段直接显示预览，服务器文件提供缩略图选择列表；支持相册、本地文件与已有作品上传，视频首帧自动加载，其他文件使用 Quick Look 预览。
- **工作流页内生成结果**：底部仅显示最新任务（含整批生成）的实时预览和产物。
- **删除任务与作品**：任务删除保留作品；作品可从本机移除，或通过新版插件永久删除电脑文件。
- **图片缓存**：原图和缩略图共享内存与磁盘缓存，并发请求合并；“连接”页可清理缓存。
- **节点折叠收纳**：按提示词、媒体、模型、采样、尺寸和输出等功能分组，再按节点展开或折叠，状态自动记住。
- **画布视图**：按原始 ComfyUI 坐标展示节点、分组和连线，支持拖动、缩放、子图与节点详情。
- 节点依赖列表；保持原始节点连接与自定义结构化输入，不猜测画布 widget 到 API 的映射。
- ComfyUI Pocket 插件：在浏览器中使用 ComfyUI 自己的 `graphToPrompt()` 自动转换（含子图），不上传到外部服务。
- Actions 的 Python 插件测试、Swift 核心测试、可选 iOS 模拟器 UI 冒烟测试、IPA 和插件 ZIP 发布。

## 安装和连接

1. 从 [Releases](https://github.com/xbunax/comfyuipocket/releases) 下载插件 ZIP，解压成 `ComfyUI/custom_nodes/comfyui_pocket/`，重启 ComfyUI。
2. ComfyUI 需要监听手机能访问的网卡，例如 `python main.py --listen 0.0.0.0 --port 8188`。
3. 安装 iOS 26+ 客户端。`unsigned.ipa` 必须先自行签名；不能直接点击安装。`signed.ipa` 的可安装设备由证书与描述文件决定。
4. 外网访问时，在 iPhone 安装并连接 Tailscale 官方 App，让手机与电脑处于同一 Tailnet，然后在“连接”中填写电脑的 Tailscale IP（通常为 `100.x.x.x`）。同一 Wi-Fi 下直接填写局域网 IP 即可。
5. 用浏览器打开 ComfyUI 页面（可以在 Pocket 侧栏查看状态）。插件会自动导出 `workflows/` 目录中的全部工作流；手机连接后自动同步，无需再点“从电脑同步”或逐个保存。

自动转换发生在 ComfyUI 浏览器页面内，因为只有前端知道节点控件与 API 输入的对应关系。ComfyUI 页面关闭后，手机仍可运行已同步的工作流，但不会感知新的工作流改动，直到再次打开页面。

## 自动同步

- 桌面：Pocket 侧栏每 5 秒检查 `user/<用户>/workflows/`，只转换新增或修改过的文件，并删除已不存在工作流对应的目录条目。
- 手机：连接时、回到前台时、编辑后约 1.5 秒以及每 10 秒自动同步。两端的修改按“有未发送编辑的一侧优先”合并。
- 删除：在手机上删除会同时删除服务端目录条目；服务端删除会移除没有未发送编辑的手机副本。
- 手机修改只更新 Pocket 目录中的参数，不会改写 ComfyUI 原始的 `.json` 工作流文件。工作流若依赖服务端未安装的自定义节点，转换可能产生占位类型，执行时会报错。

## Tailscale 组网

Pocket 不再内置 VPN 或 Go `tsnet`。请安装 Tailscale 官方 iOS App 并登录同一 Tailnet，然后填写电脑的 Tailscale IP 和端口。iOS 会通过系统 VPN 路由该连接；应用本身只访问你填写的 IP 与端口，不经过额外的 Pocket 中转服务器。

官方 Tailscale 会根据网络情况选择直连或 DERP 中继，Pocket 不控制这一选择。如需严格直连，请在 Tailnet 的 ACL/策略中限制。查看 [网络设计](docs/NETWORKING.md)。

## GitHub Actions 与签名

`main` 的每次 push 运行插件与 Swift 核心测试并上传构建产物。推送 `vX.Y.Z` 标签，或在 **Build and Release → Run workflow** 输入新标签，会在测试通过后创建 Release。

默认没有证书时发布 `ComfyUIPocket-unsigned.ipa`。要导出签名 IPA，在仓库 Actions secrets 中配置：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | 签名证书 P12 的 Base64 |
| `IOS_CERTIFICATE_PASSWORD` | P12 密码 |
| `IOS_PROVISION_PROFILE_BASE64` | 描述文件的 Base64 |
| `IOS_KEYCHAIN_PASSWORD` | 构建临时 Keychain 密码 |

可选 Actions variables：`IOS_BUNDLE_ID`（默认 `com.xbunax.comfyuipocket`）、`IOS_SIGNING_IDENTITY`（默认 `Apple Distribution`）、`IOS_EXPORT_METHOD`（默认 `release-testing`）。证书、App ID、描述文件和导出方式必须匹配。不要将这些材料提交到仓库。

Release 同时包含插件 ZIP 和 SHA256 校验文件。构建失败不会发布不完整 Release。默认构建 IPA，由用户在真机验收；手动运行 workflow 时勾选 `run_simulator_tests` 可执行模拟器 UI 测试。

## 开发

```text
ios/Pocket/              SwiftUI 界面、API 客户端、工作流模型与自动同步
server/comfyui_pocket/   ComfyUI 插件、全量工作流导出与侧栏
scripts/                 图标、插件打包、签名等辅助脚本
tests/                   插件单元测试
.github/workflows/       云端构建与发布
```

Windows 可运行 Python 验证，不需要 Xcode：

```powershell
python -m pip install aiohttp
python -m unittest discover -s tests -v
python scripts/check_local_workflows.py D:\AI_video\workflows
python scripts/package_plugin.py
```

本机验证路径为 `D:\AI_video\ComfyUI`。真实工作流和提示词不会复制进此公开仓库。

当前版本是开发预览。真实 iPhone 的组网、暂停恢复、签名安装和完整生成链路仍需设备验收。工作流编辑器支持参数编辑和画布布局查看，节点新增和重连仍在电脑端完成；自定义对象/数组输入保持原样。

## 参考与许可

交互目标参考 ComfyLink；本项目独立实现，不复制其品牌、素材或云服务协议。使用 [ComfyUI 官方 API](https://docs.comfy.org/development/comfyui-server/comms_routes)、[Apple Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)、[Tailscale iOS](https://tailscale.com/download/ios)。本项目 MIT，第三方组件保留各自许可证。
