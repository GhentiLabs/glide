// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlideKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GlideCore", targets: ["GlideCore"]),
        .library(name: "HotkeyEngine", targets: ["HotkeyEngine"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "Recognizer", targets: ["Recognizer"]),
        .library(name: "Inserter", targets: ["Inserter"]),
        .library(name: "Overlay", targets: ["Overlay"]),
        .executable(name: "glide-bench", targets: ["GlideBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4"),
    ],
    targets: [
        .target(name: "GlideCore"),
        .target(name: "HotkeyEngine"),
        .target(name: "AudioCapture"),
        .target(name: "Recognizer", dependencies: ["GlideCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "Inserter"),
        .target(name: "Overlay", dependencies: ["GlideCore"]),
        .executableTarget(name: "GlideBench", dependencies: ["GlideCore", "Recognizer", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "GlideCoreTests", dependencies: ["GlideCore"]),
        .testTarget(name: "HotkeyEngineTests", dependencies: ["HotkeyEngine"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
    ]
)
