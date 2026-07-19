// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingCopilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingCopilot", targets: ["MeetingCopilot"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingCopilot",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "MeetingCopilotTests",
            dependencies: ["MeetingCopilot"]
        )
    ]
)
