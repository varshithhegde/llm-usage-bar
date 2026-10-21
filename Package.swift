// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LLMUsageBar",
            path: "Sources/LLMUsageBar",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
