// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComfyUIPocketCore",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [.library(name: "ComfyUIPocketCore", targets: ["ComfyUIPocketCore"])],
    targets: [
        .target(name: "ComfyUIPocketCore", path: "ios/Pocket",
                exclude: ["ActivityViews.swift", "Networking.swift", "PocketApp.swift", "PocketStore.swift", "WorkflowViews.swift", "Assets.xcassets"],
                sources: ["Models.swift"]),
        .testTarget(name: "PocketCoreTests", dependencies: ["ComfyUIPocketCore"], path: "ios/Tests"),
    ]
)
