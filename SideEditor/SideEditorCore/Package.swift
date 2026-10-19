// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SideEditorCore",
    products: [
        .library(name: "SideEditorCore", targets: ["SideEditorCore"]),
    ],
    targets: [
        .target(name: "SideEditorCore", path: "Sources"),
        .testTarget(name: "SideEditorCoreTests", dependencies: ["SideEditorCore"]),
    ]
)
