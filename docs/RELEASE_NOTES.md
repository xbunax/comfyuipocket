ComfyUI Pocket v0.13.0

- Add IP / P2P connection tabs. Pair with a computer-generated QR code, QR photo,
  pasted complete invitation or comfypocket link; retain saved peer identity.
- Integrate official iroh-ffi 1.2.0 on iOS and Python. Disable relay transport on
  both endpoints throughout connection/reconnection; report direct-path failure.
- Add opt-in desktop pairing management, five-minute single-use invitations,
  persistent authorization, device revocation and P2P shutdown.
- Carry HTTP, original custom-node canvas, WebSockets, uploads and media Range
  requests over authenticated QUIC streams. Keep cache/task identity stable when
  the phone's private loopback port changes.
- Requires Pocket plugin 0.9.0 plus its optional P2P requirements. Existing IP
  connections remain available. Preserve Xcode 27.1 and resizable mirror support.

Device IPA build only; no simulator tests. Real iPhone/cellular direct-path
availability depends on network/NAT conditions and must be checked on the device.
