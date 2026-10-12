// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "tmux-whisperd",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .executable(
      name: "tmux-whisperd",
      targets: ["tmux-whisperd"]
    ),
    // Shared engine, protocol, and socket server for the daemon and the
    // future native macOS app.
    .library(
      name: "TmuxWhisperKit",
      targets: ["TmuxWhisperKit"]
    ),
    // Lowkey: the native menu-bar dictation app (assembled into Lowkey.app by
    // tools/build-lowkey-app.sh).
    .executable(
      name: "Lowkey",
      targets: ["Lowkey"]
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
      name: "TmuxWhisperKit",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      path: "Sources/TmuxWhisperKit"
    ),
    .executableTarget(
      name: "tmux-whisperd",
      dependencies: ["TmuxWhisperKit"],
      path: "Sources/tmux-whisperd"
    ),
    .testTarget(
      name: "TmuxWhisperKitTests",
      dependencies: ["TmuxWhisperKit"],
      path: "Tests/TmuxWhisperKitTests"
    ),
    // Catches Objective-C exceptions (AVAudioEngine raises them), which
    // Swift can't.
    .target(
      name: "LowkeyObjC",
      path: "Sources/LowkeyObjC"
    ),
    // Pure, testable logic for Lowkey (no AppKit).
    .target(
      name: "LowkeyCore",
      dependencies: ["LowkeyObjC"],
      path: "Sources/LowkeyCore"
    ),
    .executableTarget(
      name: "Lowkey",
      dependencies: ["LowkeyCore"],
      path: "Sources/Lowkey",
      // AppKit/Carbon/AVAudioEngine callbacks predate strict concurrency;
      // the app shell uses Swift 5 mode, the core stays in Swift 6 mode.
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "LowkeyCoreTests",
      // TmuxWhisperKit only to check DaemonClient against the real server
      // and protocol types.
      dependencies: ["LowkeyCore", "TmuxWhisperKit"],
      path: "Tests/LowkeyCoreTests"
    ),
  ]
)
