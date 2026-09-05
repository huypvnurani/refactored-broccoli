// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacCharge",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacCharge",
            path: "Sources/MacCharge"
        )
    ]
)
