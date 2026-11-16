ComfyUI Pocket v0.9.1

- Fix mobile canvas startup: wait until ComfyUI finishes node registration and
  extension setup before loading a workflow. The previous early graph-ready check
  could produce UNKNOWN widgets and large parameter mismatch counts on cold starts.
- Node wheel: scroll vertically to select a node, with selection haptics. The selected
  node fills the native parameter area. In dedicated plugin controls, the same wheel
  centers and fits the actual node within both viewport dimensions. Viewport fitting
  never changes node geometry. Overview and connection tools remain available.
- Canvas mismatch recovery stays visible as read-only nodes with exact field details
  and retry. Save/run are paused until resolved; existing layout and parameters are
  preserved. Rebuilding with a copy is available inside the details sheet.
- Respect hidden named scalar widgets, equivalent serialized custom JSON, delayed
  widget initialization and executed node modes from the saved API prompt. Widget
  edits resolve by name so dynamic plugin controls cannot shift an indexed edit.

Existing server plugin v0.6.0 is compatible; no reinstall is needed.
No simulator tests are run. Sign the unsigned IPA before installing; touch behavior
and final layout should be verified on the physical iPhone.
