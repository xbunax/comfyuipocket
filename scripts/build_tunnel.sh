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
go build -trimpath -buildmode=c-archive -o libPocketTunnel.a .
