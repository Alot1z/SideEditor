// swift-tools-version:5.9
import PackageDescription

// The editor surface consumed by the SideStore app target through a local
// package reference in AltStore.xcodeproj (XCLocalSwiftPackageReference
// "SideEditor/SideEditorCore" -> product "SideEditorCore").
//
// The domain targets are UIKit-free and Foundation-only, so the same code builds
// on macOS/Linux for `swift test` in CI and inside the iOS app.
let package = Package(
    name: "SideEditorCore",
    platforms: [
        // Matches IPHONEOS_DEPLOYMENT_TARGET in the app target.
        .iOS(.v15),
        // Only so `swift test` on a macOS runner has a sensible floor.
        .macOS(.v13),
    ],
    products: [
        .library(name: "SideEditorCore", targets: ["SideEditorCore"]),
    ],
    targets: [
        .target(name: "SideEditorCore"),
        .testTarget(name: "SideEditorCoreTests", dependencies: ["SideEditorCore"]),
    ]
)
