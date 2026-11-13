ComfyUI Pocket v0.8.0

- Canvas mode now opens the actual ComfyUI editor inside the app. Add and delete
  nodes, move and resize them, edit all server-provided widgets, connect ports,
  use groups/subgraphs, and copy/paste or undo/redo through the editor commands.
- Mobile tools provide a searchable node library, input/output port selection,
  disconnect, fit/zoom, export, save and run. Existing ComfyUI menus remain available.
- Canvas snapshots save the layout and executable API prompt together, autosave
  on the phone, and sync through Pocket. Running uses Pocket's existing task tracking.
- API-only workflows can be reconstructed into editable canvases by ComfyUI.
  Parameter/layout mismatches require an explicit rebuild with a preserved copy.
  Empty canvases can be saved as drafts. Unchanged 64-bit seeds remain intact.
- Background sync protects the active editor. Embedded pages do not scan unrelated
  desktop workflows. Sync keeps newer local edits made while an upload is in flight.

Update the server plugin to v0.6.0 for embedded-editor sync isolation and empty
canvas drafts. Other editor operations use ComfyUI's own frontend.
Device IPA testing is performed by the user; simulator UI tests are optional.
Sign ComfyUIPocket-unsigned.ipa before installing. SHA256SUMS.txt checks all assets.
