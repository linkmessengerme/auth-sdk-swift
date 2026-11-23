// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LinkAuth",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [.library(name: "LinkAuth", targets: ["LinkAuth"])],
    targets: [
        // Prebuilt protocol core. Sources: https://github.com/linkmessengerme/auth-sdk
        .binaryTarget(
            name: "LinkAuthCoreFFI",
            url: "https://github.com/linkmessengerme/auth-sdk-swift/releases/download/v0.2.0/LinkAuthCoreFFI.xcframework.zip",
            checksum: "c8e193a7c9f65de134006e03c63e6530ae1b5a4106713900c9a85a6d12e6d3fa"
        ),
        .target(name: "LinkAuthCore", dependencies: ["LinkAuthCoreFFI"],
            linkerSettings: [.linkedFramework("Security"), .linkedLibrary("resolv")]),
        .target(name: "LinkAuth", dependencies: ["LinkAuthCore"]),
    ],
    // UniFFI 0.31.2 callback trampolines compile in Swift 5 mode. Its public
    // types are Sendable; clients can consume this package from Swift 6.
    swiftLanguageVersions: [.v5]
)
