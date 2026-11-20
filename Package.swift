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
            url: "https://github.com/linkmessengerme/auth-sdk-swift/releases/download/v0.1.0/LinkAuthCoreFFI.xcframework.zip",
            checksum: "60add39a317742cb0a75d249c691231d18fc03d2277bbce2a7f3866d05f1a0f0"
        ),
        .target(name: "LinkAuthCore", dependencies: ["LinkAuthCoreFFI"],
            linkerSettings: [.linkedFramework("Security"), .linkedLibrary("resolv")]),
        .target(name: "LinkAuth", dependencies: ["LinkAuthCore"]),
    ],
    // UniFFI 0.31.2 callback trampolines compile in Swift 5 mode. Its public
    // types are Sendable; clients can consume this package from Swift 6.
    swiftLanguageVersions: [.v5]
)
