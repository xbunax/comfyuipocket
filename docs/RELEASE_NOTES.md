ComfyUI Pocket v0.15.0

- Test the active paired iroh connection from the Connection tab. The app reports median round-trip latency, download Mbps and acknowledged upload Mbps. A manual test sends 2 MiB each way. Plugin 0.10.0 adds the authenticated diagnostic stream. Existing pairings and older clients remain compatible.
- See actual connection stages, inspect the current session log and retry during backoff.
- Settings → Appearance → Workflow Canvas adds optional tap-to-focus in overview. It starts off. A tap on a node title or body focuses the original node and updates navigation; editing, links, drags and two-finger gestures keep their native behavior.
- Resume a workflow from the workbench, see batch progress, and browse Output with a thumbnail filmstrip. The compact canvas adds a live minimap and a single-line hardware summary. On wide windows the inspector shows bookmarked nodes, available sampling controls and the latest output.
