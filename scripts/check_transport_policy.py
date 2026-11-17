"""Check the effective ATS policy required by user-selected HTTP IP servers."""

import pathlib
import plistlib
import sys


def check(path):
    with pathlib.Path(path).open("rb") as source:
        info = plistlib.load(source)
    policy = info.get("NSAppTransportSecurity", {})
    if policy.get("NSAllowsArbitraryLoads") is not True:
        raise SystemExit("HTTP ComfyUI servers require NSAllowsArbitraryLoads = true")
    # On modern iOS, the presence of any of these keys overrides the global
    # exception, including when the fine-grained key is explicitly false.
    overrides = {
        "NSAllowsLocalNetworking",
        "NSAllowsArbitraryLoadsInWebContent",
        "NSAllowsArbitraryLoadsForMedia",
    }.intersection(policy)
    if overrides:
        raise SystemExit("ATS HTTP exception is overridden by: " + ", ".join(sorted(overrides)))
    if policy.get("NSExceptionDomains"):
        raise SystemExit("Per-domain ATS rules require review for user-selected servers")
    if not info.get("NSLocalNetworkUsageDescription", "").strip():
        raise SystemExit("Local network access description is missing")
    print("Transport policy OK: user-selected HTTP IPv4/IPv6 servers and local network access")


if __name__ == "__main__":
    check(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1] / "ios/Info.plist")
