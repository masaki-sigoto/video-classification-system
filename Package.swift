// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenVault",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ScreenVault",
            path: "ScreenVault",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ScreenVaultTests",
            dependencies: ["ScreenVault"],
            path: "ScreenVaultTests"
        )
    ]
)
