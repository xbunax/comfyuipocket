ComfyUI Pocket v0.14.2

- Preserve the computer’s IPv4 and IPv6 UDP ports across ComfyUI restarts. If a port is occupied, retain the other family where possible and save the new ports for the next restart.
- Retry saved addresses first, then perform fresh iroh address lookup using the same paired identity. Foreground sessions reconnect with backoff and save the refreshed ticket immediately. If neither route is reachable, scanning a new code for the same computer refreshes its address.
- Add P2P phase logs in the ComfyUI log and on iOS. Log timestamps, stages and failure categories without printing keys, tickets or QR tokens.
- Update the computer plugin to 0.9.1 and restart ComfyUI once. Existing identities and approved devices are migrated in place. The first restart after upgrading from 0.9.0 may require one address refresh because older versions did not save UDP ports.

Device IPA build with no simulator run. Connections require a direct IP path.
