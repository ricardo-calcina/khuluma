// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "KhulumaNative",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .executable(
      name: "khulumad",
      targets: ["khulumad"]
    ),
    // Shared engine, protocol, and socket server for the daemon and the
    // app's integration tests.
    .library(
      name: "KhulumaDaemonKit",
      targets: ["KhulumaDaemonKit"]
    ),
    // Khuluma: the native menu-bar dictation app (assembled into
    // Khuluma.app by tools/build-khuluma-app.sh).
    .executable(
      name: "Khuluma",
      targets: ["Khuluma"]
    ),
  ],
  dependencies: [
    // 0.12.x only: 0.13+ changed the transcription API and model files, so
    // moving on needs its own migration. 0.12.6 makes AsrManager an actor,
    // which the Swift 6.3 compiler requires.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.12.6")),
  ],
  targets: [
    .target(
      name: "KhulumaDaemonKit",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      path: "Sources/KhulumaDaemonKit"
    ),
    .executableTarget(
      name: "khulumad",
      dependencies: ["KhulumaDaemonKit"],
      path: "Sources/khulumad"
    ),
    .testTarget(
      name: "KhulumaDaemonKitTests",
      dependencies: ["KhulumaDaemonKit"],
      path: "Tests/KhulumaDaemonKitTests"
    ),
    // Catches Objective-C exceptions (AVAudioEngine raises them), which
    // Swift can't.
    .target(
      name: "KhulumaObjC",
      path: "Sources/KhulumaObjC"
    ),
    // Pure, testable logic for the app (no AppKit).
    .target(
      name: "KhulumaCore",
      dependencies: ["KhulumaObjC"],
      path: "Sources/KhulumaCore"
    ),
    .executableTarget(
      name: "Khuluma",
      dependencies: ["KhulumaCore"],
      path: "Sources/Khuluma",
      // AppKit/Carbon/AVAudioEngine callbacks predate strict concurrency;
      // the app shell uses Swift 5 mode, the core stays in Swift 6 mode.
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "KhulumaCoreTests",
      // KhulumaDaemonKit only to check DaemonClient against the real server
      // and protocol types.
      dependencies: ["KhulumaCore", "KhulumaDaemonKit"],
      path: "Tests/KhulumaCoreTests"
    ),
  ]
)
