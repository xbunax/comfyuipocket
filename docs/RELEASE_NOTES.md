Native SwiftUI client for iOS 26+ with Liquid Glass, direct IP/port pairing,
mobile workflow parameter panels, queue/progress, image upload and gallery,
and embedded Tailscale with direct-only application traffic.

- `ComfyUIPocket-unsigned.ipa`: requires your own signing before installation; it is not directly installable.
- `ComfyUIPocket-signed.ipa` (when signing secrets are configured): installation is restricted by the embedded provisioning profile.
- `comfyui_pocket-plugin.zip`: extract to `ComfyUI/custom_nodes/`, then restart ComfyUI.
- `SHA256SUMS.txt`: checksums of release assets.

The first release is a development preview. Simulator tests do not establish
physical-device NAT traversal or background behavior. Tailscale control/discovery
uses a coordination service; workflow/image traffic has no application relay.
The app runs its embedded node in the foreground and reconnects after suspension.
