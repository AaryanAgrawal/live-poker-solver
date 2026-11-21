// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LivePokerSolver",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "LivePokerSolver", path: "Sources/LivePokerSolver")]
)
