ComfyUI Pocket v0.2.0

- All workflows saved in ComfyUI sync to the phone automatically. No per-workflow
  selection or manual save step; new, edited and deleted workflows are mirrored.
- Phone parameter edits and renames sync back to the server catalog automatically.
- Embedded Tailscale was removed. Use the official Tailscale iOS app (or a LAN IP)
  and enter the computer's IP and port directly. The IPA is smaller and no longer
  carries a VPN runtime or Go bridge.
- Server plugin converts every workflow with ComfyUI's own `graphToPrompt()`,
  including subgraphs, so links, custom nodes and widget values keep their meaning.

Assets:

- `ComfyUIPocket-unsigned.ipa`: requires your own signing before installation.
- `ComfyUIPocket-signed.ipa` (when signing secrets are configured): installable
  devices are limited by the embedded provisioning profile.
- `comfyui_pocket-plugin.zip`: extract to `ComfyUI/custom_nodes/`, restart ComfyUI,
  then open ComfyUI in a browser once so automatic export can run.
- `SHA256SUMS.txt`: checksums of release assets.

The first release of this version is a development preview. Simulator tests do not
establish physical-device behavior, Tailscale routing, or background behavior.
Tailscale connections are managed by the official app; depending on the network it
may use DERP relaying. The Pocket app itself contacts only the IP and port you enter.
