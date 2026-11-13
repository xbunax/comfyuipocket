ComfyUI Pocket v0.4.1

- Prompt blocks now use compact, wrapping word chips inside category cards instead
  of a vertical list of text editors. Inline block mode and the full-screen
  visual editor both use the new layout.
- Tap a chip to edit its text, weight, enabled state and category. Long-press and
  drag chips to reorder them or move them between categories. Drop targets are
  highlighted; canceling a drag does not change prompt order.
- Add, rename, collapse and reorder categories. Removing a category keeps its
  words in Uncategorized. Categories, disabled words and ordering persist on the
  phone for each prompt field, including when switching back to plain text.
- Chip detail settings include iOS system translation with automatic source
  detection and English/Chinese language controls. The translated text is shown
  first and only replaces the chip after tapping Use Translation. Weight and
  category remain unchanged. First use may require a system language download.
- Saved prompt versions, raw text editing and existing workflow functionality
  remain available. Merely opening or canceling the visual editor does not rewrite
  the original prompt.

The ComfyUI plugin is unchanged; update only the iOS IPA.
Simulator tests are not run for this release. The IPA is built directly for device
installation and physical-device testing. Sign the unsigned IPA before installing.
