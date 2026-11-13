# Network behavior

LAN: `Swift URLSession → user's IP:port → ComfyUI`.

Tailnet: `Swift URLSession → authenticated 127.0.0.1 ephemeral listener → tsnet.Dial → direct WireGuard/UDP → user's Tailscale IP:port`.

The loopback listener is inside the iOS application process. It is not a third-party
server and never binds to LAN interfaces. Every HTTP/WebSocket request requires a
random 256-bit bridge header. The proxy has one validated fixed IP/port target,
does not accept CONNECT, strips the private bridge header, verifies HTTPS normally,
and closes active connections when replaced/stopped. It never falls back to the
device's ordinary network for a Tailscale target.

`prepare_tailscale.py` pins upstream v1.104.7 and fails if audited code changes.
It closes the DERP connection gate and drops non-discovery traffic addressed to
peer-relay GENEVE endpoints, including batched sends and inbound WireGuard traffic.
The app cannot exchange application traffic over DERP/Peer Relay. Peers can use
direct encrypted disco messages and STUN to establish UDP paths. Disabling DERP
discovery reduces NAT traversal success compared with ordinary Tailscale.

The control plane (Tailscale login/coordination, or a user-selected Headscale
server), STUN and direct discovery are separate from the ComfyUI data plane. "No relay"
does not mean "no coordination server". A restrictive firewall/NAT can make this
policy unable to connect; the app returns an error instead of silently relaying.
Support-log uploads are disabled in the embedded node.

State keys are in the app's protected Application Support directory, excluded from
device backup. No auth key is bundled with the app. Login happens in the system
browser. No VPN entitlement is needed; the embedded node has normal iOS foreground
lifetime. WebSockets reconnect with bounded backoff, polling reconciles missed
history, and foreground transitions reconnect the event channel.

ComfyUI itself is generally unauthenticated. Protect access with a trusted LAN,
Tailscale ACLs, or a TLS/authentication gateway appropriate to your deployment.
The initial client supports ComfyUI's default user profile, not interactive gateway
logins. Local HTTP is intentionally supported; HTTPS validates certificates normally.

## Device acceptance

1. Same-LAN IPv4/IPv6: pair, import, change prompt/seed, run, preview, cancel pending,
   download/save/share; verify server graph links unchanged.
2. Tailscale: interactive enrollment, ACL-denied peer, valid peer, Wi-Fi/cellular
   transition, airplane mode, suspension/foreground reconnect.
3. Inspect traffic while UDP is blocked: workflow requests must fail and must not
   reach the server over DERP/peer relay. Never describe simulator tests alone as
   proof of this device/network property.
4. Export a graph containing custom nodes/subgraphs; compare ComfyUI's native API
   prompt to the submitted prompt after editing one scalar field.
5. Verify both unsigned re-signing and signed IPA installation on a permitted device.
