// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacCharge",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // SMC access, shared by the app (reads) and the fan helper (writes).
        .target(
            name: "SMCCore",
            path: "Sources/SMCCore"
        ),
        .executableTarget(
            name: "MacCharge",
            dependencies: ["SMCCore"],
            path: "Sources/MacCharge"
        ),
        // Installed setuid-root by the app so fan writes reach the SMC.
        .executableTarget(
            name: "MacChargeFanHelper",
            dependencies: ["SMCCore"],
            path: "Sources/MacChargeFanHelper"
        ),
    ]
)
