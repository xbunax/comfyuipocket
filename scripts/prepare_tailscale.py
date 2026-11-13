"""Fetch pinned upstream source and enforce the Pocket data-plane policy.

The patch disables DERP connections and blocks WireGuard data/handshakes through
peer relays. Control-plane coordination and STUN remain enabled. Exact-match guards
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
    code = patch(code,
        "pt, isGeneveEncap := packetLooksLike(b)\n\tsrc := epAddr{ap: ipp}",
        "\n\t// Pocket: do not accept WireGuard traffic received through peer relays.\n"
        "\tif isGeneveEncap && pt != packetLooksLikeDisco { return true, false }\n")
    path.write_text(code, encoding="utf-8", newline="\n")
    derp = ROOT / "wgengine/magicsock/derp.go"
    code = derp.read_text(encoding="utf-8")
    anchor = "func (c *Conn) wantDerpLocked() bool { return c.derpMap != nil }"
    if code.count(anchor) != 1:
        raise RuntimeError("Tailscale DERP connection gate changed; review policy")
    derp.write_text(code.replace(anchor, "func (c *Conn) wantDerpLocked() bool { return false } // Pocket: no DERP connections"), encoding="utf-8", newline="\n")
    test = ROOT / "wgengine/magicsock/pocket_policy_test.go"
    test.write_text('''package magicsock
import (
    "net/netip"
    "testing"
    "tailscale.com/tailcfg"
    "tailscale.com/types/key"
)
func TestPocketRelayPolicy(t *testing.T) {
    c := new(Conn)
    if c.wantDerpLocked() { t.Fatal("DERP connection gate is open") }
    sent, err := c.sendAddr(netip.AddrPortFrom(tailcfg.DerpMagicIPAddr, 1), key.NodePublic{}, []byte{1}, false, false)
    if sent || err != nil { t.Fatal("DERP data was not dropped") }
    sent, err = c.sendUDP(netip.MustParseAddrPort("127.0.0.1:1234"), []byte{1}, false, true)
    if sent || err != nil { t.Fatal("Peer Relay data was not dropped") }
}
''', encoding="utf-8")
    licenses = ROOT.parents[1] / "ios/Pocket/Resources"
    licenses.mkdir(parents=True, exist_ok=True)
    (licenses / "Tailscale-LICENSE.txt").write_bytes((ROOT / "LICENSE").read_bytes())
    (ROOT / "POCKET_PATCH.txt").write_text(
        f"Upstream {VERSION}. Pocket disables DERP connections and blocks Peer Relay data.\n"
        "Control coordination and STUN remain enabled. No optional relay fallback.\n", encoding="utf-8")
    print(f"Prepared Tailscale {VERSION} with enforced direct-only application traffic")


if __name__ == "__main__":
    main()
