#!/bin/bash
set -euo pipefail
sdk="${POCKET_SDK:-iphoneos}"
arch="${POCKET_ARCH:-arm64}"
target="${arch}-apple-ios26.0"
if [[ "$sdk" == "iphonesimulator" ]]; then target="${target}-simulator"; fi
exec xcrun --sdk "$sdk" clang -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" "$@"
