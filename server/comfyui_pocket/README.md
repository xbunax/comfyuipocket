# ComfyUI Pocket server plugin

Copy this folder into `ComfyUI/custom_nodes/comfyui_pocket` and restart ComfyUI.
IP mode needs no extra packages or model node. Optional P2P pairing (plugin 0.10.0)
requires installing this folder's requirements.txt using ComfyUI's Python:

```powershell
& '<ComfyUI>/.venv/Scripts/python.exe' -m pip install -r '<ComfyUI>/custom_nodes/comfyui_pocket/requirements.txt'
```

Open Pocket > 手机 P2P 配对 > 生成配对码, then scan the QR or paste the complete
code in the app's P2P tab. Each invitation expires in five minutes and admits one
new phone. Paired identities survive restarts; revoke devices or disable P2P in
the sidebar. P2P starts only when requested, then resumes on restart until disabled.
iroh relays are disabled on both endpoints for their entire lifetime. Discovery
may contact iroh's public discovery services, but application traffic requires a
direct UDP/QUIC path. Some NAT/mobile networks cannot connect; failure is explicit.
This is a complete invitation code, not a six-digit lookup service.

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

Version 0.7.0 adds `GET /pocket/v1/outputs?folder=&offset=0&limit=60` and the
`output-browser` capability. It lists one level of the configured ComfyUI output
directory, with folders first and media files newest first. Pages contain at most
100 entries, file sizes and modification timestamps. Existing `/view` serves the
media. Listing does not depend on task history, scan subdirectories recursively,
or follow symbolic links / Windows junctions. User access is checked before listing.
Update the plugin and restart ComfyUI to enable the phone's Historical Output tab.

Version 0.11.0 adds the canvas asset sidebar. GET /pocket/v1/inputs lists
the input directory, and POST /pocket/v1/media/import prepares selected
media for a loader node. Existing inputs are reused. Outputs are copied
to a stable filename in the input directory while leaving the original in place.

Catalog entries include `updatedAt` (milliseconds). The plugin respects ComfyUI's
`comfy-user` storage routing. Bounded JSON, atomic writes, stable 32-hex identifiers,
and origin validation prevent path traversal, partial files and browser cross-origin
writes. Files written before automatic sync receive a timestamp from their modification
time.

These endpoints share ComfyUI's network trust boundary; they do not add authentication
to ComfyUI. Use a trusted LAN or Tailscale with ACLs, never an exposed public port.

Version 0.5.0 adds `POST /pocket/v1/media/delete` with JSON filename, subfolder and type (output/temp only). The phone offers a confirmation before permanent deletion. This endpoint validates origin/user routing, rejects traversal, nonmedia files and symlinks, and is idempotent for missing files. Update the plugin and restart ComfyUI to enable server-file deletion; phone-only gallery removal does not require it.
