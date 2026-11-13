ComfyUI Pocket v0.6.1

- Restore the editable prompt input inside each workflow. Tap Edit mode beside
  it to open the full-screen text/word-block editor. Word weights, translation,
  categories, saved versions and apply/discard behavior remain available.
- Display a node's numeric width and height side by side, with width on the left
  and height on the right. Common resolution presets update both together:
  512x512, 768x768, 1024x1024, 832x1216, 1216x832, 1280x720 and 720x1280.
  Unsupported presets are disabled according to the node schema. Linked inputs
  and dimensions from different nodes are never combined or replaced.
- Simplify batch settings to one immediate 1-20 count slider, without a Done
  button or extra toggle. Swipe down to dismiss. Subsequent generations continue
  to randomize seeds by default; the batch is still shown as one task.

The server plugin remains v0.5.0; no reinstall is required for this update.
Simulator tests are skipped. The device IPA is compiled directly for user testing.
Sign ComfyUIPocket-unsigned.ipa before installing. SHA256SUMS.txt checks all assets.
