#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export POCKET_SDK="${1:-iphoneos}"
export POCKET_ARCH="${2:-arm64}"
export GOOS=ios CGO_ENABLED=1
export GOARCH="$POCKET_ARCH"
if [[ "$GOARCH" == "x86_64" ]]; then export GOARCH=amd64; fi
export CC="$PWD/scripts/clang-ios.sh"
chmod +x "$CC"
cd native
cache="cache/$POCKET_SDK-$POCKET_ARCH"
# Hash all bridge/policy inputs so restoring a broader Actions cache is still safe.
digest=$(cat bridge.go go.mod ../scripts/prepare_tailscale.py ../scripts/clang-ios.sh | shasum -a 256 | cut -d ' ' -f 1)
if [[ -f "$cache/$digest/libPocketTunnel.a" ]]; then
  cp "$cache/$digest/libPocketTunnel.a" libPocketTunnel.a
else
  go build -trimpath -buildmode=c-archive -o libPocketTunnel.a .
  mkdir -p "$cache/$digest"
  cp libPocketTunnel.a "$cache/$digest/libPocketTunnel.a"
fi
