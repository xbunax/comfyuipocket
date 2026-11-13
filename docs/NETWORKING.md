# Network behavior

## Connecting

LAN: `Swift URLSession → user's IP:port → ComfyUI`.

Tailscale: install the official Tailscale iOS app, sign in to the same tailnet as the
computer, and enter the computer's Tailscale IP (usually `100.x.x.x`). iOS routes the
request through the system VPN tunnel provided by the official app. Pocket contains no
VPN implementation, no embedded node, no loopback proxy and no relay of its own. It
contacts only the IP and port you enter.

The official Tailscale app decides whether a connection is direct or relayed through
DERP. Pocket has no visibility into or control over that choice; "no Pocket relay" does
not mean "Tailscale can never relay". If you need strict direct-only behavior, enforce
it with Tailscale ACLs/policy on your tailnet rather than the Pocket client.

`Info.plist` permits cleartext HTTP because ComfyUI commonly runs without TLS, and asks
for Local Network permission when the address is on the local network. Use HTTPS if a
TLS gateway is in front of ComfyUI.

## Automatic workflow sync

The server plugin exposes ComfyUI's own saved workflows to the desktop page:

- `GET /pocket/v1/comfy-workflows` lists every `user/<user>/workflows/**/*.json` file.
- `GET /pocket/v1/comfy-workflows/file?path=...` returns one file, path-checked and
  size-bounded.

The Pocket sidebar extension polls the listing every five seconds. Changed files are
converted inside the ComfyUI page with ComfyUI's own `app.graphToPrompt()` on a
throwaway graph, so links, widget values, custom nodes and subgraphs keep their
meaning. Subgraph node types are registered only for the duration of each conversion
and then restored. The resulting API prompt and original UI graph are written to
`user/<user>/pocket/catalog/<32-hex>.json`, keyed by a stable hash of the workflow path.

The iPhone syncs this catalog automatically:

- On connect, on returning to the foreground, after local edits (1.5 s debounce) and
  every ten seconds while connected.
- New and changed server entries are pulled. Local edits are never overwritten while
  they are pending; they are pushed to the catalog instead.
- Deleting a phone copy deletes the catalog entry; deleting a catalog entry or a
  ComfyUI workflow removes clean phone copies. Copies with unsent phone edits are kept.
- Phone edits update the catalog entry only. They do not rewrite the original `.json`
  file under ComfyUI's `workflows/` directory.

Sync requires the plugin and the ComfyUI browser page. Conversion has to run in the
browser because only the frontend maps graph widgets to API inputs. Workflows with
unregistered custom nodes may convert with placeholder types and fail at execution;
install the same custom nodes on the server.

`updatedAt` is a server-side millisecond timestamp, advanced monotonically on each
write. The client uses it to decide whether to fetch a catalog entry. Request bodies
are limited to 20 MiB and validated as ComfyUI API graphs before storage.

ComfyUI itself is generally unauthenticated. Protect access with a trusted LAN,
Tailscale ACLs, or a TLS/authentication gateway appropriate to your deployment. The
plugin does not add authentication to ComfyUI and must not be exposed to the public
internet.

## Device acceptance

1. Same-LAN IPv4/IPv6: pair, run a server workflow, edit prompt/seed, verify the phone
   library picks up desktop changes without pressing sync.
2. Create, rename, modify and delete a workflow in ComfyUI; confirm the phone library
   mirrors each change.
3. Edit a parameter and rename a workflow on the phone; confirm the catalog entry
   updates and the ComfyUI workflow file is unchanged.
4. Delete a workflow on either side; confirm clean copies disappear on the other side,
   and that a phone copy with unsent edits is retained.
5. Tailscale: enroll the official app, connect over Wi-Fi and cellular, test
   suspend/foreground reconnect and ACL-denied peers.
6. Install both the unsigned re-signing path and (when configured) the signed IPA.
