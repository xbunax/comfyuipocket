# ComfyUI Pocket server plugin

Copy this folder into `ComfyUI/custom_nodes/comfyui_pocket` and restart ComfyUI.
No additional Python packages, external service, background upload, or model node is required.

Open the **Pocket** sidebar in ComfyUI, open a workflow, give it a name, and select
**保存当前工作流到 Pocket**. The frontend calls ComfyUI's `graphToPrompt()` and stores
both the API prompt and original UI graph locally under `user/<user>/pocket/catalog`.
On iPhone choose **工作台 → + → 从电脑同步**.

API: `GET /pocket/v1/info`, `GET/POST /pocket/v1/workflows`,
`GET/DELETE /pocket/v1/workflows/{id}`. The plugin respects ComfyUI's `comfy-user`
storage routing. UUID-only identifiers, bounded JSON, atomic writes, and origin
validation prevent path traversal, partial files and browser cross-origin writes.

These endpoints share ComfyUI's network trust boundary; they do not add authentication
to ComfyUI. Use a trusted LAN or Tailscale with ACLs, never an exposed public port.
