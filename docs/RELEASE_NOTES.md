ComfyUI Pocket v0.9.0

- Touch canvas is now drawn by the native iOS interface: readable compact cards,
  original-layout mode, group navigation, node search, pan/pinch zoom, node parameter
  sheets, movement in original-layout mode, and explicit node/group execution states.
  Compact arrangement is a view preference and never rewrites the original graph.
- ComfyUI remains the graph execution/serialization engine. Specialized plugin
  controls are available separately; add/connect/disconnect, undo/redo, save and run
  continue to operate on the same graph. Node deletion also removes its connections.
- Common/all parameter modes reduce clutter. Chinese prompt, seed and dimension
  fields are recognized. LoRA slots are grouped, and face refinement/upscale/frame
  interpolation have their own section. Existing prompt block editing is preserved.
- K2/Qwen reference images have previews, local/photo/gallery selection, ordering
  and deletion. Existing masks and extension metadata survive reordering.
- H3 contiguous text storyboards have prompt cards, frame duration, add/reorder/delete,
  synchronized derived inputs and inactive track preservation. Complex media/audio,
  retakes, gaps and trimmed timelines use the dedicated plugin control.
- H3 named properties are restored before graph configuration so the plugin's cached
  editor matches mobile edits. Frame-equivalent second rounding no longer prevents
  opening the canvas. Unrecognized custom serializers still report mismatches.

Requires the existing Pocket server plugin v0.6.0; no reinstall is needed for this update.
No simulator tests are run. Sign the unsigned IPA and test touch interactions on device.
