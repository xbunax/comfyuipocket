ComfyUI Pocket v0.6.0

- Open each workflow prompt in a dedicated full-screen editor. The workflow shows
  a compact preview; the editor offers a spacious text area and a word-block
  switch, with word weights, categories, drag ordering and translation preserved.
- Apply edits to the workflow explicitly, or discard the draft. Existing saved
  prompt versions remain available. Switching modes without editing preserves the
  original text; incoming sync changes prompt a conflict confirmation on apply.
- Refresh the overall layout with consistent grouped cards, spacing, subtle mint
  accents, readable workflow rows and task status badges. The gallery uses image
  cards; connection help is collapsible. The workflow run bar emphasizes the run
  action and keeps batch settings nearby. Light and dark appearances use system
  colors, with adaptive layouts for status and editor actions.
- Prompt bindings resolve workflow identity when applying, so background sync
  reordering cannot redirect an edit to a different workflow.

The server plugin remains v0.5.0; no reinstall is required for this update.
Simulator tests are skipped. The device IPA is compiled directly for user testing.
Sign ComfyUIPocket-unsigned.ipa before installing. SHA256SUMS.txt checks all assets.
