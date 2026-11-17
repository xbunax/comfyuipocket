ComfyUI Pocket v0.9.3

- Keep text inputs focused while the keyboard changes the canvas viewport. Node
  refitting and automatic serialization pause during text/IME editing, so keyboard
  layout changes cannot move the input out of view or refocus another node.
- Tapping an original node text field zooms and positions that field within the
  visible canvas above the keyboard. Long text areas are capped to available
  height and retain their own scrolling; effective text size stays readable.
- The node wheel and full toolbar temporarily give way to a compact Done Input
  control. Finish editing or leave the field to restore the exact prior canvas
  scale and offset, then resume automatic saving. Switching fields preserves the
  original return view. Original DOM controls are retained, with no replacement
  text editor and no changes to node geometry or connections.
- Works with standard multiline widgets and tested custom controls in H3 Director,
  K2/Qwen Merge Workbench and WorkFisher workflows.

Existing server plugin v0.6.0 is compatible; no reinstall is needed.
Device IPA archive only, with no simulator tests. Sign the unsigned IPA before
installing. Keyboard behavior is checked in the browser; final iPhone IME and
keyboard interactions should be verified on the physical device.
