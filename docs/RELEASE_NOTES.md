ComfyUI Pocket v0.14.0

- Ship the Liquid Glass canvas layout: compact workflow capsule, top run control,
  adaptive hardware strip, floating bottom tools and a large-window node sidebar.
  Respect Reduce Transparency with opaque control surfaces.
- Phone favorites open as a medium/large sheet with search, current-node
  highlighting, named subgraph breadcrumbs and swipe-to-remove. Selecting a
  favorite focuses the original graph node. Large windows retain the sidebar.
- Move node appearance to Settings > Appearance > Workflow Canvas. It is off
  by default. The optional theme changes the renderer's node body color only;
  preserve functional title colors, ports, geometry, custom controls and graph
  serialization. Disabling restores the original renderer.
- Favorite canvas nodes per server and workflow. Tap the star in the bottom bar
  to save the focused node, search favorites, remove favorites or jump directly
  to the original node fitted to the canvas. The large-window navigator also
  has per-node stars and an only-favorites filter.
- Preserve nested subgraph paths and node type identity. Removed/replaced nodes
  remain marked unavailable; undo can restore them without losing the bookmark.
- Add seven persisted colorways: Celadon, Iris, Bay, Amber, Graphite, Gruvbox and
  Catppuccin Mocha. Light/dark/system appearance; community light companions are
  Gruvbox Light and Catppuccin Latte. Theme native backgrounds, cards, text,
  controls and prompt chips; preserve original ComfyUI node functional colors.
- Unify native surfaces and reduce list section spacing. Preserve native system
  navigation materials. The HTML files in docs are illustrative proposals;
  glass refraction and controls use native SwiftUI in the shipped app.

Pocket plugin remains 0.9.0; no reinstall required. Device IPA build only, no
simulator tests. Verify touch targeting, theme appearance and nested-node
navigation on a physical iPhone/iPad.
