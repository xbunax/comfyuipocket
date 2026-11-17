import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class ThemeTests: XCTestCase {
    private func luminance(_ hex: UInt32) -> Double {
        let values = [16, 8, 0].map { shift -> Double in
            let value = Double((hex >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
    func testReadableTextAndAccentAcrossAllLightAndDarkSurfaces() {
        for theme in PocketColorway.allCases {
            for dark in [false, true] {
                let colors = theme.tokens(dark: dark)
                for text in [colors.text, colors.secondary, colors.accent] {
                    for surface in [colors.background, colors.surface] {
                        let a = luminance(text), b = luminance(surface)
                        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme) dark=\(dark) contrast=\(ratio)")
                    }
                }
            }
        }
    }
}
