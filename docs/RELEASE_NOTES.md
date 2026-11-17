ComfyUI Pocket v0.9.2

- The workflow canvas now always displays the real ComfyUI graph, including its
  original layout, links, groups, image previews and custom node controls.
- Open to the full workflow overview. Scroll the vertical node wheel to center
  and enlarge the selected original node within the available canvas, with
  selection haptics. The previous separate parameter-card view is removed.
- Overview returns to the whole graph; Focus Node fits the current selection
  again. Two-finger pan and pinch zoom use the actual graph's touch controls.
  Rotation and viewport changes refit the current node or overview.
- Give the graph the full web viewport. Desktop progress/resource overlays are
  hidden, and floating canvas toolbars can be enabled from Canvas Tools when
  needed. Graph editing, port connections, subgraphs, save and run remain available.
- Camera navigation preserves node positions, sizes, connections and parameters.

Existing server plugin v0.6.0 is compatible; no reinstall is needed.
Device IPA archive only, with no simulator tests. Sign the unsigned IPA before
installing; final touch behavior and layout should be verified on the iPhone.
