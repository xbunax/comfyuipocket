ComfyUI Pocket v0.3.0

- Batch generation: queue up to 12 tasks from the workflow page. Subsequent tasks can
  automatically receive fresh random seeds.
- Prompt library: save, edit, search and insert reusable prompts from any text prompt
  field, with one-tap saving of the current prompt.
- Workbench: pin workflows to the top and collapse name-prefix groups.
- Task details: open queued, running or recent tasks to see outputs, live preview,
  the exact prompts and every submitted parameter.
- Workflow results: generated images and videos appear directly on the workflow page,
  with a live preview while the task runs.
- Media inputs: LoadImage / LoadVideo fields now show a real preview and can take a
  local photo/video or an existing generated work (uploaded to ComfyUI input).
- The in-app Tailscale reminder was removed. Networking still uses the IP and port
  you enter, with the official Tailscale app if you need remote access.

Automatic all-workflow sync from v0.2.0 is unchanged. The plugin ZIP is unchanged
from v0.2.0; updating the IPA alone is enough for the new client features.

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
