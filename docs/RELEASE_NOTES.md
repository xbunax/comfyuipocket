ComfyUI Pocket v0.14.1

- Wait for ComfyUI's saved workflow tabs to finish restoring before opening the
  requested canvas. Previously, restoration could replace the requested graph
  after node setup, producing false class_type mismatches across an entire prompt.
- Verify graph identity and node IDs before applying mobile parameters. Retry a
  displaced load once, and stop safely if another graph remains active. Never
  assign parameters to a different node type that happens to reuse the same ID.
- Check graph ownership again after asynchronous export so a workflow switch
  cannot save another canvas into the current workflow.
- Add regression coverage for delayed tab restoration, displaced graph loads,
  and node ID collisions. Preserve the original workflows and custom nodes.
- Preserve custom nodes that already serialize in bypass mode. In particular,
  Goohai Qwen's string-only bypass must retain its goohai_bypass flag and must
  not be switched into normal model execution when opening the canvas.

Pocket plugin remains 0.9.0; no reinstall required. Device IPA build only, no
simulator tests. Verify opening MiniMax, Qwen and switching between cached
canvases on a physical iPhone/iPad.
