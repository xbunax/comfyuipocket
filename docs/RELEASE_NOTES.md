ComfyUI Pocket v0.5.0

- Delete task records from the task list or details. Pending generations in that
  task are canceled; currently running generations must be stopped first. Generated
  works are preserved independently of task history.
- Delete works from the gallery or preview. Remove from this phone only, or
  permanently delete the matching server output/temp file with Pocket plugin
  v0.5.0. Deleted works stay removed after refresh and their image caches are purged.
- Workflow results show only the newest submission, including every generation in
  a batch. A pending, failed or empty newest task does not display older results.
- Shared memory/disk image caching covers originals, thumbnails, input images and
  video first frames. Simultaneous requests share one load. Cache keys separate
  servers and generations, uploads/deletions invalidate cached content, and cache
  storage is bounded at 32 MB in memory and 256 MB on disk. Clear it in Connection.
- Set batch generation count with a slider from 1 to 20, keeping the random-seed
  toggle and one-task batch presentation.
- Workflow parameters are organized by function, then by node. Collapse or expand
  individual nodes, function groups, or all nodes; expansion state is remembered.
  Parameter pinning, ordering and editing remain available.

Plugin update:

Install the new comfyui_pocket-plugin.zip over the existing plugin and restart
ComfyUI to enable permanent server-file deletion. Existing plugins can still run
workflows, sync and use phone-only work removal. The new endpoint only permits
media files under output/temp; input files, traversal and symbolic links are rejected.

Simulator tests are skipped. The device IPA is compiled directly for user testing.
Sign ComfyUIPocket-unsigned.ipa before installing. SHA256SUMS.txt checks all assets.
