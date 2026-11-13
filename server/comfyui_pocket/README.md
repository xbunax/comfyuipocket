# ComfyUI Pocket server plugin

Copy this folder into `ComfyUI/custom_nodes/comfyui_pocket` and restart ComfyUI.
No additional Python packages, external service, background upload, or model node is required.

Open the **Pocket** sidebar in ComfyUI to see sync status. Every workflow saved under
the ComfyUI user's `workflows/` directory is exported automatically — no per-workflow
selection or save button. The browser extension converts each workflow with ComfyUI's
own `graphToPrompt()` (including subgraphs) and stores both the API prompt and the
original UI graph under `user/<user>/pocket/catalog`. The iPhone pulls the catalog
automatically and pushes parameter edits back into it.

Automatic sync requires the ComfyUI browser page to be open once after the workflows
change; conversion runs in that page because only the frontend knows the node/widget
mapping. Phone edits update the Pocket catalog entry, not the original `.json` file
in the ComfyUI workflows directory.

API: `GET /pocket/v1/info`, `GET /pocket/v1/comfy-workflows`,
`GET /pocket/v1/comfy-workflows/file?path=...`, `GET/POST /pocket/v1/workflows`,
`GET/DELETE /pocket/v1/workflows/{id}`.

Catalog entries include `updatedAt` (milliseconds). The plugin respects ComfyUI's
`comfy-user` storage routing. Bounded JSON, atomic writes, stable 32-hex identifiers,
and origin validation prevent path traversal, partial files and browser cross-origin
writes. Files written before automatic sync receive a timestamp from their modification
time.

These endpoints share ComfyUI's network trust boundary; they do not add authentication
to ComfyUI. Use a trusted LAN or Tailscale with ACLs, never an exposed public port.
