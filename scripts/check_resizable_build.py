"""Check the archived build's SDK opt-in for resizable iPhone Mirroring."""

import pathlib
import plistlib
import struct
import sys


def check(path):
    with pathlib.Path(path).open("rb") as source:
        info = plistlib.load(source)
    sdk = info.get("DTSDKName", "")
    if not sdk.startswith("iphoneos") or not sdk.removeprefix("iphoneos").split(".")[0].isdigit():
        raise SystemExit("Missing iPhoneOS SDK metadata in archived app")
    if int(sdk.removeprefix("iphoneos").split(".")[0]) < 27:
        raise SystemExit("Resizable iPhone Mirroring requires a build linked with iOS 27 SDK or later")
    if int(info.get("DTXcode", "0")) < 2700:
        raise SystemExit("Expected Xcode 27 or later")
    if not isinstance(info.get("UIApplicationSceneManifest"), dict):
        raise SystemExit("Scene-based application lifecycle is required")
    if info.get("UIRequiresFullScreen", False):
        raise SystemExit("Full-screen compatibility mode blocks continuous window resizing")
    if sorted(info.get("UIDeviceFamily", [])) != [1, 2]:
        raise SystemExit("Expected the universal iPhone/iPad app")
    # The linker SDK in Mach-O controls compatibility behavior. A plist-only
    # version change must never pass this check.
    binary = pathlib.Path(path).with_name(info["CFBundleExecutable"]).read_bytes()
    if binary[:4] != b"\xcf\xfa\xed\xfe":
        raise SystemExit("Expected the device app's 64-bit Mach-O executable")
    offset = 32
    linked_sdk = None
    for _ in range(struct.unpack_from("<I", binary, 16)[0]):
        command, size = struct.unpack_from("<II", binary, offset)
        if size < 8 or offset + size > len(binary):
            raise SystemExit("Invalid Mach-O load command")
        if command == 0x32 and size >= 24:  # LC_BUILD_VERSION
            platform, minimum, linked_sdk, tools = struct.unpack_from("<IIII", binary, offset + 8)
            if platform != 2:  # PLATFORM_IOS (not simulator or Catalyst)
                raise SystemExit("Expected an iPhoneOS device build")
            break
        offset += size
    if linked_sdk is None or linked_sdk >> 16 < 27:
        raise SystemExit("Executable must actually link against iOS 27 SDK or later")
    linked_version = f"{linked_sdk >> 16}.{(linked_sdk >> 8) & 255}"
    print(f"Resizable build verified: {sdk}, Mach-O SDK {linked_version}, Xcode {info['DTXcode']}, scene lifecycle, iPhone/iPad")


if __name__ == "__main__":
    check(sys.argv[1])
