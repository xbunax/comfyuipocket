ComfyUI Pocket v0.4.0

- Each Run action appears as one task, including batch runs. Task details aggregate
  outputs and completion counts, retain each generation's exact prompt and seed,
  and can cancel all pending generations in the task. Partial submission errors
  are shown without hiding already submitted generations. Batch metadata is kept
  on the server and task snapshots are saved on the phone, separately per server.
- Workbench rows now have a visible pin button, alongside swipe and long-press
  actions. Pinned workflows remain at the top across launches.
- Workflow canvas view restores saved ComfyUI node positions, sizes, groups and
  connections, with zoom, pan, node details and subgraph navigation. API-only
  imports show an explanation when no saved canvas exists. Existing phone
  libraries automatically fetch canvas data on their next sync.
- Prompt fields offer a visual card editor, plus a per-field switch for inline
  block editing. Edit, reorder, disable and weight individual blocks. Nested
  expressions, escaped commas, LoRA tags and schedules remain intact. Opening an
  editor does not rewrite the original text; Apply commits the visual draft.
  Saved prompt versions and the existing prompt library remain available.
- Image/file inputs always show a preview, including fields returned as filename
  dropdowns by ComfyUI. Server files can be selected from a preview list. Local
  photos, videos and Files imports show an upload preview; generated works can
  still be reused. Video thumbnails load automatically through AVFoundation.
  Other file formats use iOS Quick Look for supported previews.
- Generated results remain at the bottom of the workflow page.

The server plugin is unchanged from v0.2.0. Updating the IPA is sufficient.
Canvas view displays the saved layout; node creation and rewiring stay in ComfyUI.
Prompt weighting uses (text:1.20); interpretation depends on the workflow encoder.

Assets:

- ComfyUIPocket-unsigned.ipa: sign before installation.
- comfyui_pocket-plugin.zip: existing installations do not need an update.
- SHA256SUMS.txt: release asset checksums.
