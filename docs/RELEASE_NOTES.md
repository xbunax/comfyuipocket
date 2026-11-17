ComfyUI Pocket v0.12.0

- Add window-based layouts for iPad, iPad multitasking and resizable iPhone
  Mirroring windows on Mac. Wide workbenches and task pages show list/detail
  columns; narrow windows keep single-column navigation. Settings offers Auto,
  Compact and Expanded modes, with a safe minimum width for columns.
- Show artwork beside the gallery on larger windows, keeping task grouping and
  historical Output folders. Previews retain zoom, video playback and details.
- Fix the gallery's oversized/obscured title: use an inline navigation title,
  place the source selector in normal layout, and add bottom scroll clearance.
- Open the chosen default workflow view directly. Canvas mode no longer creates
  a parameter page and then presents a cover. The canvas menu can switch back to
  parameters, including while disconnected.
- Add a searchable node navigator beside the original ComfyUI canvas on large
  windows, retaining the wheel and actual node camera focus. Narrow windows keep
  the compact bottom controls; the web editor stays mounted during resizing.
- Add one shared Output layout setting for folders, images and videos: tiles,
  large tiles or a thumbnail list. Remember the choice across visits.
- Sort works by time, name or file size in either direction. Task works retain
  grouping; size order uses the sum of distinct output files per task. Read sizes
  through cached, bounded HEAD requests without downloading full media. Unknown
  sizes stay last. Historical Output sorts the entire directory before paging.
- Support left-edge swipe back in workflow/task details, previews and Output
  subfolders. Save the canvas before leaving and confirm unsaved prompt edits.
  Keep native navigation gestures and ordinary canvas gestures available.
- Add a live final-prompt preview beside the full-screen word editor when space
  permits. Keep inline prompt input, word blocks and saved prompt versions.
- Support Command-1/2/3/4 navigation and Command-Return for explicit Run/Apply
  controls. Forms use a readable maximum width; native menus and node navigation
  support pointer interaction.

Directory-wide Output sorting requires Pocket plugin v0.8.0 and a server restart.
Folder sizes are not recursively scanned; file-size order uses actual media bytes.
Device IPA build only, without simulator tests. Final touch, pointer, keyboard and
window-resizing behavior should be verified on iPad/iPhone/Mac. Resizable iPhone
Mirroring depends on supported iOS/macOS versions; the app does not change system
mirroring capabilities or force an iPad-sized screen on older systems.
