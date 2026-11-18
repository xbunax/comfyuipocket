# ComfyUI Pocket

在「连接 → P2P 配对」点「P2P 测速」，可查看这台手机与电脑之间的往返延迟、下载和上传速度。测速需要电脑端 Pocket 插件 0.10.0 或更高版本。

在「设置 → 外观与配色 → 工作流画布」打开「总览中轻点节点聚焦」后，点画布工具条的总览，再轻点节点标题或空白处即可放大该节点。

使用 SwiftUI + iOS 26 Liquid Glass 的 ComfyUI 手机客户端。通过 **IP + 端口** 或 **iroh P2P 配对** 直连自己的电脑。ComfyUI 中的全部工作流会自动双向同步，不需要逐个选择。代码在 Windows 编写，iOS 构建和 IPA 发布全部由 GitHub Actions 完成。

## 已实现

- IPv4 / IPv6 配对，HTTP / HTTPS；新增 iroh 二维码/完整配对码，严格仅直连。
- 自动同步 ComfyUI 已保存的**全部工作流**；新增、修改、重命名、删除都会自动反映到手机。
- 手机上的参数修改、重命名和删除会自动同步回服务端 Pocket 目录，无需手动上传。
- 手机参数面板：提示词优先，输入图片上传、模型选项、数值、布尔值、随机种子、参数收藏和拖动排序。
- **批量生成**：滑块设置 1–20 次，一次提交显示为一个任务，统一查看批次进度、所有产物和每次生成的实际参数，可取消全部待执行项。后续生成可自动更换随机种子。
- **分辨率与批量设置**：同节点宽高左右并排，支持 1080p、2K QHD/DCI、4K UHD/DCI 等横竖屏组合；批量次数滑块与随机种子开关即时生效，无需确认。
- **提示词可视化编辑**：工作流内提示词输入框保留文本/分块切换，点击“编辑模式”进入独立全屏编辑页，使用大文本框或分块开关，词块紧凑排列并自动换行；点按词块设置权重、启停、分类和中英翻译，长按拖动排序或跨分类移动，拖起、落点变化和移动完成时有触觉反馈；编辑模式支持按词块功能自动识别与筛选，可手动更正功能；保留提示词版本保存。复杂括号、LoRA、转义符与调度表达式保留。
- **提示词库与版本保存**：保存、编辑、搜索和管理常用提示词，在独立提示词编辑页中追加、替换或保存当前内容，点“应用”写回工作流。
- **工作台置顶与分组折叠**：工作流可置顶，按名称前缀分组并折叠收纳。
- **默认视图设置**：工作台左上角或“连接 → 设置”可选择打开工作流时默认进入参数面板或画布，偏好会保存在手机上。
- **工作流输出与文件预览**　作品页可在两个首页左右滑动切换。文件预览按电脑 output 文件夹浏览，长按图片或视频可永久删除服务器文件。浏览需要 Pocket 插件 v0.7.0 或更高版本。
- **全屏预览**　横竖屏均可全屏查看图片和视频，控件闲置后隐藏，轻点画面即可唤回。打开详情可查看文件对应的生成提示词与参数。
- **任务详情**：点开队列或历史任务，查看生成产物、实际使用的提示词和全部参数；运行中显示实时预览。
- **媒体输入预览**：图片与文件字段直接显示预览，服务器文件提供缩略图选择列表；支持相册、本地文件与已有作品上传，视频首帧自动加载，其他文件使用 Quick Look 预览。
- **工作流页内生成结果**：底部仅显示最新任务（含整批生成）的实时预览和产物。
- **删除任务与作品**：任务删除保留作品；作品可从本机移除，或通过新版插件永久删除电脑文件。
- **文件缓存**：图片、视频和缩略图复用本地磁盘缓存，不设置大小上限。可在“连接 → 文件缓存”查看占用并手动清理。
- **画布资产侧栏**：在画布顶栏打开“资产”，浏览服务器输入、输出文件夹及最近作品，长按图片或视频拖到支持该类型的节点。导入服务器输出文件需要 Pocket 插件 0.11.0。
- **节点折叠收纳**：按提示词、媒体、模型、采样、尺寸和输出等功能分组，再按节点展开或折叠，状态自动记住。
- **完整可编辑画布**：在 App 内直接使用服务器上的 ComfyUI 编辑器，支持新增/删除节点、拖动布局、连接/断开端口、编辑控件、分组与子图、复制粘贴、撤销重做、导出和运行。手机工具栏提供节点搜索和端口选择，修改会自动保存并同步回参数面板。
- **原始画布节点轮盘**：打开时展示完整工作流布局，上下滚动轮盘后，画布自动平移、缩放并居中放大选中的原始节点，直接使用该节点的真实控件。点击“总览”返回全图，“聚焦节点”重新放大；双指平移和缩放可自由调整视角，横竖屏变化后重新适配。默认收起浮动工具，需要时可在“画布工具”中开启。
- **画布文本输入**：点击原节点的文本框会自动放大并定位到键盘上方，输入期间暂停整节点聚焦和自动保存，保留中文输入法的组合输入。点“完成输入”或离开输入框后恢复原视角，再自动保存修改。
- **画布缓存**：工作流参数与布局自动保存到本机，最近两个编辑器会保留并复用；内容未变时再次进入保留节点和视角，内容变化时只更新图数据。网页资源使用持久缓存，内存紧张时释放未使用的编辑器。App 重启后仍需初始化编辑器，完整画布和生成操作需要连接服务器。
- **紧凑画布操作区**：顶部运行并显示排队结果、执行状态及硬件指标，底部仅保留总览、节点选择、面板开关和工具。节点轮盘按需展开；资产、工作流标签和周边面板可显示或隐藏。使用手机菜单切换已同步工作流，会先保存当前内容并复用对应缓存。
- **服务器硬件栏**：标准 ComfyUI 接口提供 RAM/VRAM；若服务器已有 NodeUI 资源接口，会额外读取 CPU/GPU 利用率。未知值显示“—”，点指标可查看硬件名称和用量详情，无需安装新插件即可使用标准内存指标。
- 节点依赖列表；保持原始节点连接与自定义结构化输入，不猜测画布 widget 到 API 的映射。
- ComfyUI Pocket 插件：在浏览器中使用 ComfyUI 自己的 `graphToPrompt()` 自动转换（含子图），不上传到外部服务。
- Actions 的 Python 插件测试、Swift 核心测试、可选 iOS 模拟器 UI 冒烟测试、IPA 和插件 ZIP 发布。

## iPad 与 Mac 镜像布局

设置中的“界面布局”可选自动、紧凑单栏或大屏分栏。布局以当前窗口宽度为准，
适配 iPad 分屏和支持调整窗口大小的 iPhone 镜像；不根据设备型号强制放大。
宽窗口可并排查看工作流/任务列表与详情、作品与预览，画布提供节点导航侧栏。
⌘1–4 切换页面，⌘Return 运行画布/参数面板，或应用独立编辑页中的提示词。
镜像自由调整窗口比例需要 iOS 27、macOS 27 和支持的手机型号；App 必须使用 iOS 27 SDK 构建。
本项目使用 Xcode 27.1，仍支持安装在 iOS 26 上；旧系统的镜像只能等比例缩放。

文件预览的布局菜单同时控制文件夹与媒体的平铺、大图或列表。
排序菜单支持时间、名称、大小及升降序。工作流输出按任务合计大小排序，未知大小置后。
目录排序需要插件 v0.8.0，在完整目录排序后分页，文件夹优先且不递归计算其大小。
支持左侧边缘滑动返回：画布先保存，提示词有未应用修改时会确认，Output 返回父目录。

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
scripts/                 插件打包、签名等辅助脚本
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

完整画布需要连接服务器，使用服务器安装的 ComfyUI 前端和自定义节点控件。API-only 工作流会由 ComfyUI 自动重建可编辑布局。若旧画布与手机当前参数不能对应，会提示保留副本后重建，避免静默覆盖参数。保存会同时更新 API 参数和画布，空画布可作为草稿保存。画布编辑期间后台同步不会覆盖当前内容；编辑器内置的 ComfyUI 保存命令仍可保存电脑端原始工作流文件。

当前版本是开发预览。真实 iPhone 的触控手感、暂停恢复、签名安装和完整生成链路由用户在真机验收。

## 参考与许可

自 v0.17.5 起，ComfyUI Pocket 自有的客户端、插件及图标素材采用 PolyForm Noncommercial License 1.0.0，允许按许可证条款进行非商业使用、修改和分发。商业使用需取得版权方授权。此前按 MIT 发布的版本继续适用当时的许可，第三方组件适用各自的许可证。[许可证](LICENSE) · [版权声明](NOTICE)

项目独立实现，交互设计参考 ComfyLink。使用 [ComfyUI 官方 API](https://docs.comfy.org/development/comfyui-server/comms_routes)、[Apple Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)、[Tailscale iOS](https://tailscale.com/download/ios)。

## Optional P2P pairing (v0.13.0)

The connection page offers IP and P2P tabs. Update the computer plugin to 0.9.0,
install its requirements.txt with ComfyUI's Python, then generate an invitation
in the Pocket sidebar. Scan the QR or paste the entire code on the phone within
five minutes. Saved phones reconnect without a new code; the desktop can revoke
access or disable P2P. Both iroh endpoints disable relay transport for their full
lifetime. When a direct UDP path cannot be established, the app reports failure.
Public discovery may be used to find addresses; application traffic never relays.
See [network behavior](docs/NETWORKING.md) for transport, identity and test details.
