// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Prototypes",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "vpcapture", path: "Sources/vpcapture"),
        .executableTarget(name: "systap", path: "Sources/systap"),
        .target(name: "CRing", path: "Sources/CRing"),
        .executableTarget(name: "relay", dependencies: ["CRing"], path: "Sources/relay"),
    ],
    swiftLanguageModes: [.v5]
)
