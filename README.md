<p align="center">
  <img src="ios/Artwork/AppIcon.svg" alt="ComfyUI Pocket 图标" width="120" height="120">
</p>

<h1 align="center">ComfyUI Pocket</h1>

<p align="center">在 iPhone 和 iPad 上编辑、运行和管理自己的 ComfyUI 工作流。</p>

<p align="center"><a href="https://github.com/xbunax/comfyuipocket/releases/latest">下载 App 和 ComfyUI 插件</a></p>

ComfyUI Pocket 是一款面向自托管 ComfyUI 的移动客户端。手机通过 IP 和端口或 iroh P2P 配对连接电脑，生成任务由电脑上的 ComfyUI 执行。App 提供参数面板和原生工作流画布，支持 iOS 和 iPadOS 26 或更新版本。

## 主要特点

- **工作流与画布** — 自动同步电脑上保存的工作流，可置顶常用流程。在画布中编辑原有节点、连线和子图，收藏节点后可快速定位。
- **参数与提示词** — 在参数面板编辑模型、尺寸、种子和媒体输入，支持全屏提示词编辑、可视化分块和提示词库。
- **画布资产** — 浏览服务器的输入、输出和最近作品。选中图片或视频后点击目标节点，也可直接拖入支持的节点。画布资产导入需要 Pocket 插件 0.11.0 或更新版本。
- **批量生成与任务** — 长按画布的运行按钮可一次提交 1–20 次生成，可为每次生成随机设置种子。整批生成归为一个任务，保留每次生成的参数和结果。
- **作品与文件** — 支持文件夹浏览、全屏预览、布局切换和排序。图片和视频可缓存到本机，缓存占用可在连接页查看和清理。
- **连接与布局** — 支持 IPv4、IPv6 和仅直连的 iroh P2P 配对。P2P 可测延迟、上传和下载速度。界面采用 Liquid Glass，适配 iPad 和宽窗口。

## 安装 ComfyUI 插件

### 1. 下载并解压

下载 `comfyui_pocket-plugin.zip`，将解压得到的 `comfyui_pocket` 文件夹放入正在运行的 ComfyUI 使用的 `custom_nodes` 目录。 [下载 Release](https://github.com/xbunax/comfyuipocket/releases/latest)

安装后的目录应如下所示。

```text
ComfyUI/
└── custom_nodes/
    └── comfyui_pocket/
        ├── __init__.py
        ├── requirements.txt
        └── web/
```

### 2. 安装 P2P 依赖（可选）

只使用 IP 连接时可直接进入下一步。需要扫码或配对码连接时，用 **ComfyUI 自己的 Python 环境**安装插件依赖，再启动服务。

Windows 虚拟环境版，在 ComfyUI 根目录运行。

```powershell
& .\.venv\Scripts\python.exe -m pip install -r .\custom_nodes\comfyui_pocket\requirements.txt
```

Windows 便携版，在包含 `python_embeded` 和 `ComfyUI` 的便携包根目录运行。 [ComfyUI 便携版文档](https://docs.comfy.org/installation/comfyui_portable_windows)

```powershell
& .\python_embeded\python.exe -m pip install -r .\ComfyUI\custom_nodes\comfyui_pocket\requirements.txt
```

macOS 或 Linux 手动安装版，在 ComfyUI 根目录激活其 Python 环境后运行。

```bash
python -m pip install -r custom_nodes/comfyui_pocket/requirements.txt
```

### 3. 重启并验证

重启 ComfyUI，然后打开或刷新电脑端的 ComfyUI 网页，在侧栏找到 **Pocket**。也可以在电脑浏览器打开下方的插件接口。返回含有 `version` 字段的 JSON 就表示插件已经加载。端口按你的服务器配置填写。 [检查插件状态](http://127.0.0.1:8188/pocket/v1/info)

第一次使用时，让 ComfyUI 网页加载完毕。Pocket 插件会在网页中转换已保存的工作流，手机连接后即可自动同步。以后在电脑保存工作流后，再打开该网页即可转换改动。手机上的参数编辑会写入服务器的 Pocket 工作流目录。

## 安装 App 并连接

从同一 Release 下载 IPA，使用你的侧载工具安装。`ComfyUIPocket-unsigned.ipa` 需要用侧载工具签名。 [下载 App](https://github.com/xbunax/comfyuipocket/releases/latest)

| 连接方式 | 操作 |
| --- | --- |
| **同一 Wi‑Fi 下用 IP** | 在 App 的「连接 → IP 连接」分别填写电脑 IP 和端口（默认 `8188`）。使用普通 HTTP 的 ComfyUI 时关闭 HTTPS。首次访问局域网时允许系统的「本地网络」权限。 |
| **iroh P2P** | 在电脑 ComfyUI 的「Pocket → 手机 P2P 配对」生成配对码。手机选择「连接 → P2P 配对」，扫描二维码或粘贴完整配对码。已配对设备可自动重连，连接仅使用直连。 |
| **Tailscale** | 将手机和电脑加入同一个 Tailnet，在 App 的「IP 连接」填写电脑的 Tailscale IP 和 ComfyUI 端口。路线由 Tailscale 决定。 |

如果手机通过 IP 访问电脑，请让 ComfyUI 监听手机可访问的网卡。可以在已有启动命令末尾加上 `--listen 0.0.0.0 --port 8188` 以开启 IPv4 局域网访问。请在可信网络中使用 ComfyUI 的 HTTP 接口。 [网络与同步说明](docs/NETWORKING.md)

## 文档与开发

- [电脑端插件说明](server/comfyui_pocket/README.md)
- [网络与工作流同步](docs/NETWORKING.md)
- [当前发布说明](docs/RELEASE_NOTES.md)

<details>
<summary>本地测试和 CI 构建</summary>

`ios/Pocket/` 包含 SwiftUI 客户端，`server/comfyui_pocket/` 包含 ComfyUI 插件。

```bash
python -m pip install 'aiohttp>=3.12,<4' pyyaml -r server/comfyui_pocket/requirements.txt
python -m unittest discover -s tests -v
node --test tests/canvas_bridge.test.cjs
```

Swift 核心测试可在 macOS 上运行 `swift test`。GitHub Actions 使用 Xcode 27.1 构建设备 IPA，随 Release 提供插件 ZIP 和 SHA256 校验文件。可在「Build and Release」工作流中选用模拟器测试。

配置签名版 IPA 时，可通过 Actions Secrets 提供 `IOS_CERTIFICATE_P12_BASE64`、`IOS_CERTIFICATE_PASSWORD`、`IOS_PROVISION_PROFILE_BASE64` 和 `IOS_KEYCHAIN_PASSWORD`。可选的 Actions Variables 包括 `IOS_BUNDLE_ID`、`IOS_SIGNING_IDENTITY` 和 `IOS_EXPORT_METHOD`。

</details>

## 许可证

自 v0.17.5 起，ComfyUI Pocket 自有的客户端、插件及图标素材采用 PolyForm Noncommercial License 1.0.0。商业使用需取得版权方授权。此前按 MIT 发布的版本继续适用当时的条款，第三方组件适用各自的许可证。 [许可证](LICENSE) · [版权声明](NOTICE)
