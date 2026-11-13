ComfyUI Pocket v0.7.0

- Replace the old SwiftUI chip drag wrapper with native drag/drop interactions
  on the word itself, explicitly enabled on iPhone. Long-press the word to lift,
  move over a highlighted word/category, and release to reorder or move groups.
  Inline and full-screen editors use the same implementation. Canceling a drag
  leaves the document unchanged; only a completed drop changes the order.
- Add light haptics at lift, selection feedback when the drop target changes,
  and a soft confirmation after a successful move. Real drag-session callbacks
  reset visual state on cancellation; item provider filenames are not used for
  local session validation. Only words from the same board are accepted.
- In Edit mode, identify word functions locally from English/Chinese keywords:
  subject/scene, style/material, composition, lighting, camera/depth of field,
  color, quality/details, negative/exclusions and other. Filter the visible words
  by function and see counts, while the full prompt remains intact for generation.
- Word details allow a manual function override or return to automatic detection.
  Function metadata, grouping, weights and original prompt syntax are preserved.
  Existing saved word boards remain compatible. Unknown phrases stay in Other.

The server plugin remains v0.5.0; no reinstall is required for this update.
Simulator tests are skipped. The device IPA is compiled directly for user testing.
On-device drag feel and haptics need verification on an iPhone.
Sign ComfyUIPocket-unsigned.ipa before installing. SHA256SUMS.txt checks all assets.
