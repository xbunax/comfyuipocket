ComfyUI Pocket v0.6.2

- Widen workflow prompt inputs by removing node-content indentation, reducing
  row margins and allowing the input to fill the available width. Inline editing
  and the separate full-screen Edit mode remain available. Restore the inline
  word-block switch with word details, weights, translation and dragging. Both
  editors share the prompt and mode preference; returning refreshes saved groups.
- Add 1080p, 2K QHD, 2K DCI, 4K UHD and 4K DCI resolution presets in landscape
  and portrait, plus 1536 and 2048 square sizes. Quick choices stay in the row;
  All presets lists every combination with its exact dimensions. Node constraints
  still disable unsupported sizes.
- Restore the random-seed switch below the immediate batch count slider. Enabled
  randomizes later generations; disabled reuses the configured seeds throughout
  the batch. No confirmation button is needed.

- The saved prompt library now offers Append and Replace current prompt modes.
  Replacement updates the editor draft and its word blocks together, retaining
  the saved version's exact text. Apply commits it; Cancel can discard it.

The server plugin remains v0.5.0; no reinstall is required for this update.
Simulator tests are skipped. The device IPA is compiled directly for user testing.
Sign ComfyUIPocket-unsigned.ipa before installing. SHA256SUMS.txt checks all assets.
