ComfyUI Pocket v0.10.0

- Cache the two most recently used canvases per server/workflow. Reopening an
  unchanged graph reuses its live WebKit editor and viewport; changed parameters
  or layout update graph data within the existing runtime. Workflow data already
  persists on disk, and WebKit now keeps its persistent resource cache. Idle pages
  are released under memory pressure. Manual Reload Canvas refreshes the runtime.
- Compact mobile layout: run moves to the top, with visible save/queue/error and
  execution feedback. The bottom becomes one compact action row; the vertical
  node wheel expands only when requested. Add a native saved-workflow picker.
- Toggle ComfyUI assets, sidebar and workflow chrome on/off. Hidden chrome stays
  hidden even when an extension resets focus mode. Guard against overwriting the
  original phone workflow after switching graphs from the web UI.
- Canvas Run waits for an ongoing save, commits text editing, saves the actual
  current graph and reports the accepted task ID or submission error in the canvas.
- Server hardware bar shows real GPU/CPU utilization and RAM/VRAM usage. Standard
  system_stats provides memory; an already-installed NodeUI resource provider
  supplies optional utilization metrics. Unavailable readings remain unknown.
- Fix slow K2/Qwen startup handling: track setup completion and public coordinate
  readiness instead of relying solely on a private frontend field. Allow complex
  extension initialization up to three minutes with stage-specific progress and
  errors. No early loading before node registration.

Existing Pocket server plugin v0.6.0 remains compatible; no reinstall is required.
After restarting the app the editor still initializes once, and full canvas editing
and generation require a server connection. Browser checks cover current workflows;
no real generation jobs were submitted for verification. No simulator tests are run.
Sign the unsigned device IPA and verify final layout/touch behavior on the iPhone.
