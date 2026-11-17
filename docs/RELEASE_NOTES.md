ComfyUI Pocket v0.12.1

- Fix iPhone Mirroring remaining at the phone aspect ratio on supported systems:
  build with Xcode 27.1 / iOS 27 SDK on the Apple silicon Xcode 27 runner. The
  previous release added adaptive layout but was still linked with iOS 26 SDK,
  which did not opt into the new freely resizable iPhone Mirroring behavior.
- Check the actual archived app's SDK/Xcode metadata, scene lifecycle, universal
  device family and full-screen flag before publishing. Isolate Swift caches by
  the new toolchain. Keep iOS 26 as the minimum deployment target.
- Clarify the layout setting: resizing the mirroring window independently in
  width/height requires iOS 27, macOS 27 and supported iPhone hardware. Older
  systems retain proportional scaling. The app follows the window size supplied
  by the system; the layout preference does not resize the system window.

All v0.12.0 features are preserved, including direct default-view entry, compact
artwork header, unified Output layouts, sorting and edge-swipe navigation.
The Pocket plugin remains v0.8.0; no reinstall is required. Device IPA build only,
without simulator tests. Sign/install the new IPA, reopen iPhone Mirroring and
check arbitrary window resizing on the supported iPhone/Mac.
