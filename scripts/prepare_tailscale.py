"""Fetch pinned upstream source and enforce the Pocket data-plane policy.

The patch keeps encrypted discovery packets over DERP for NAT traversal, but
blocks WireGuard data/handshakes through DERP and peer relays. Exact-match guards
make upstream changes fail the build instead of silently weakening the policy.
"""
import io
import pathlib
import tarfile
import urllib.request

VERSION = "v1.104.7"
ROOT = pathlib.Path(__file__).resolve().parents[1] / "native" / "tailscale-source"


def patch(source: str, anchor: str, insertion: str) -> str:
    if source.count(anchor) != 1:
        raise RuntimeError(f"Tailscale source changed; review data-plane policy: {anchor}")
    return source.replace(anchor, anchor + insertion)


def main():
    if ROOT.exists():
        raise SystemExit("tailscale-source already exists; use a clean checkout for dependency preparation")
    url = f"https://codeload.github.com/tailscale/tailscale/tar.gz/refs/tags/{VERSION}"
    archive = urllib.request.urlopen(url, timeout=120).read()
    ROOT.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        prefix = f"tailscale-{VERSION[1:]}/"
        for member in tar.getmembers():
            if not member.isfile() or not member.name.startswith(prefix):
                continue
            relative = pathlib.PurePosixPath(member.name[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Unsafe upstream archive path")
            target = ROOT.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tar.extractfile(member).read())
    path = ROOT / "wgengine/magicsock/magicsock.go"
    code = path.read_text(encoding="utf-8")
    code = patch(code,
        "func (c *Conn) sendAddr(addr netip.AddrPort, pubKey key.NodePublic, b []byte, isDisco bool, isGeneveEncap bool) (sent bool, err error) {",
        "\n\t// Pocket: no WireGuard traffic over a relay; discovery may coordinate direct UDP.\n"
        "\tif !isDisco && (addr.Addr() == tailcfg.DerpMagicIPAddr || isGeneveEncap) { return false, nil }\n")
    code = patch(code,
        "func (c *Conn) sendUDPBatch(addr epAddr, buffs [][]byte, offset int) (sent bool, err error) {",
        "\n\t// Pocket: never send batched WireGuard traffic through peer relays.\n"
        "\tif addr.vni.IsSet() { return false, nil }\n")
    code = patch(code,
        "func (c *Conn) sendUDP(ipp netip.AddrPort, b []byte, isDisco bool, isGeneveEncap bool) (sent bool, err error) {",
        "\n\tif !isDisco && isGeneveEncap { return false, nil }\n")
    path.write_text(code, encoding="utf-8", newline="\n")
    (ROOT / "POCKET_PATCH.txt").write_text(
        f"Upstream {VERSION}. Pocket blocks outbound WireGuard data and handshakes on DERP/Peer Relay.\n"
        "Discovery/control traffic remains enabled. No optional relay fallback.\n", encoding="utf-8")
    print(f"Prepared Tailscale {VERSION} with enforced direct-only application traffic")


if __name__ == "__main__":
    main()
