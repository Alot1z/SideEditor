// swift-tools-version:5.9
import PackageDescription

// The editor surface consumed by the SideStore app target through a local
// package reference in AltStore.xcodeproj (XCLocalSwiftPackageReference
// "SideEditor/SideEditorCore" -> product "SideEditorCore").
let package = Package(
    name: "SideEditorCore",
    products: [
        .library(name: "SideEditorCore", targets: ["SideEditorCore"]),
    ],
    targets: [
        .target(name: "SideEditorCore"),
    ]
)
