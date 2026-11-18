ComfyUI Pocket v0.15.2

- On return to the foreground, verify that ComfyUI is reachable over the paired connection before starting live events and workflow synchronization.
- Rebuild the local HTTP tunnel and reconnect when needed. Retain the saved pairing and the local address used by open workflow canvases.
- Show connection recovery while retrying and prevent a canceled WebSocket from closing its replacement.
