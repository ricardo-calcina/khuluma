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
    // `khuluma transcribe`, bundled as Khuluma.app/Contents/Helpers/khuluma.
    // Named khuluma-cli here: `khuluma` would collide with `Khuluma` on a
    // case-insensitive disk.
    .executable(
      name: "khuluma-cli",
      targets: ["khuluma-cli"]
    ),
    // Khuluma: the native menu-bar dictation app (assembled into
    // Khuluma.app by tools/build-khuluma-app.sh).
    .executable(
      name: "Khuluma",
      targets: ["Khuluma"]
    ),
  ],
  dependencies: [
    // Pinned exactly: minor releases change the transcription API and model
    // files. 0.15.6 reads the same Parakeet v3 folder (JointDecisionv3) as
    // FluidAudio's own cache, so one model copy can serve other apps too.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
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
    .executableTarget(
      name: "khuluma-cli",
      dependencies: ["KhulumaCore", "KhulumaDaemonKit", .product(name: "FluidAudio", package: "FluidAudio")],
      path: "Sources/khuluma-cli"
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
      // FluidAudio only for the first-run model download and its cache path;
      // transcription itself runs in the bundled khulumad.
      dependencies: ["KhulumaCore", .product(name: "FluidAudio", package: "FluidAudio")],
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
