// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComfyUIPocketCore",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [.library(name: "ComfyUIPocketCore", targets: ["ComfyUIPocketCore"])],
    targets: [
        .target(name: "ComfyUIPocketCore", path: "ios/Pocket",
                exclude: ["AppSettings.swift", "OutputBrowser.swift", "ActivityViews.swift", "ActivityActions.swift", "Networking.swift", "PocketApp.swift", "PocketStore.swift", "WorkflowViews.swift", "WorkflowParameters.swift", "Prompts.swift", "PromptStudio.swift", "PromptChipBoard.swift", "PromptWordDrag.swift", "PromptBlockDetail.swift", "EditableWorkflowCanvas.swift", "CanvasSessionCache.swift", "CanvasHardwareViews.swift", "CanvasTools.swift", "MobileCanvas.swift", "CanvasNodeWheel.swift", "WorkflowCustomEditors.swift", "CanvasBridge.js", "MediaInputs.swift", "MediaDetailViews.swift", "Assets.xcassets"],
                sources: ["Models.swift", "CanvasDocument.swift", "CanvasCache.swift", "ServerHardware.swift", "OutputDirectory.swift", "MobileWorkflow.swift", "PromptBlocks.swift", "PromptFunctions.swift", "GenerationTask.swift", "MediaArchive.swift", "MediaCache.swift"]),
        .testTarget(name: "PocketCoreTests", dependencies: ["ComfyUIPocketCore"], path: "ios/Tests"),
    ]
)
