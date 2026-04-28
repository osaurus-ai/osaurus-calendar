// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-calendar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-calendar", type: .dynamic, targets: ["osaurus_calendar"])
    ],
    targets: [
        .target(
            name: "osaurus_calendar",
            path: "Sources/osaurus_calendar"
        ),
        .testTarget(
            name: "osaurus_calendarTests",
            dependencies: ["osaurus_calendar"],
            path: "Tests/osaurus_calendarTests"
        )
    ]
)
