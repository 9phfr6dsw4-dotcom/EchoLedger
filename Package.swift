// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EchoLedger",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EchoLedgerCore", targets: ["EchoLedgerCore"]),
        .executable(name: "EchoLedgerApp", targets: ["EchoLedgerApp"])
    ],
    targets: [
        .target(
            name: "EchoLedgerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "EchoLedgerPDF", dependencies: ["EchoLedgerCore"]),
        .executableTarget(
            name: "EchoLedgerApp",
            dependencies: ["EchoLedgerCore", "EchoLedgerPDF"]
        ),
        .testTarget(
            name: "EchoLedgerTests",
            dependencies: ["EchoLedgerCore", "EchoLedgerPDF"]
        )
    ]
)
