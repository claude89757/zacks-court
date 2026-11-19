// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZacksCourt",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CourtCore", targets: ["CourtCore"]),
        .library(name: "CourtApp", targets: ["CourtApp"]),
        .executable(name: "CourtMac", targets: ["CourtMac"]),
        .executable(name: "court-probe", targets: ["CourtProbe"]),
        .executable(name: "court-analyze", targets: ["CourtAnalyze"]),
        .executable(name: "court-check", targets: ["CourtCoreChecks"])
    ],
    targets: [
        .target(name: "CourtCore", resources: [.copy("Web"), .copy("Notices")]),
        .target(name: "CourtApp", dependencies: ["CourtCore"], linkerSettings: [.linkedFramework("AVKit")]),
        .executableTarget(name: "CourtMac", dependencies: ["CourtApp", "CourtCore"]),
        .executableTarget(name: "CourtProbe", dependencies: ["CourtCore"]),
        .executableTarget(name: "CourtAnalyze", dependencies: ["CourtCore"]),
        .executableTarget(name: "CourtCoreChecks", dependencies: ["CourtCore"], path: "Tests/CourtCoreTests"),
        .testTarget(name: "CourtAppTests", dependencies: ["CourtApp"])
    ]
)
