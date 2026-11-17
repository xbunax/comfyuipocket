ComfyUI Pocket v0.11.0

- Add Settings from the workbench gear button and Connection page. Choose the
  default workflow view: parameter panel or original workflow canvas. The choice
  persists on the phone; both views remain accessible.
- Add Task Works / Historical Output tabs to the gallery. Browse the current
  server's output directory by its original folders, with breadcrumbs, newest
  media first, 60-entry pages, refresh, cached thumbnails and full media previews.
  Existing output files remain browsable even without ComfyUI task history.
- Update the Pocket plugin to v0.7.0 with a read-only paged output listing endpoint.
  Restrict it to the configured output directory; reject path traversal, symbolic
  links and Windows junctions. Switching servers resets the browser and prevents
  stale requests from showing another server's files.

Historical Output requires the new plugin and a ComfyUI restart. Task-grouped
works, existing workflows and the v0.10.1 IPv6 HTTP transport fix are preserved.
Device IPA build only; simulator tests are not run. Sign and test on an iPhone.
