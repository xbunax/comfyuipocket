ComfyUI Pocket v0.10.1

- Fix HTTP connections to user-selected IPv6 servers being blocked by App
  Transport Security. Remove the fine-grained local networking ATS key that
  overrides the existing arbitrary-load exception on current iOS. The same
  policy covers API requests, WebSocket connections, media and the canvas.
- Keep the local network privacy usage description and normal HTTPS certificate
  validation. Add a CI check of the actual archived app's transport policy before
  publishing an IPA.

Existing Pocket server plugin v0.6.0 remains compatible; no reinstall is required.
This fixes the app-side ATS rejection. The server must still listen on IPv6 and
be reachable from the phone's network. No simulator tests are run; sign and test
the device IPA on the iPhone.
