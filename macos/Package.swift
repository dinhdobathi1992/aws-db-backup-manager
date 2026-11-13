// swift-tools-version: 6.0
import PackageDescription

// Native SwiftUI rewrite of AWS DB Backup Manager (v0.2).
// ADBMCore has no third-party dependencies: AWS calls go through a small
// SigV4 client whose only callable operations are the 49 in
// docs/iam-policy.json, so destructive operations do not exist in the code.
let package = Package(
    name: "ADBM",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ADBMCore", targets: ["ADBMCore"]),
        .executable(name: "adbm-cli", targets: ["adbm-cli"]),
        .executable(name: "ADBMApp", targets: ["ADBMApp"]),
    ],
    targets: [
        .target(name: "ADBMCore"),
        .executableTarget(name: "adbm-cli", dependencies: ["ADBMCore"]),
        .executableTarget(name: "ADBMApp", dependencies: ["ADBMCore"]),
        .testTarget(
            name: "ADBMCoreTests",
            dependencies: ["ADBMCore"],
            resources: []
        ),
    ],
    swiftLanguageModes: [.v6]
)
