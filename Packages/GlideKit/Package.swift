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
        .library(name: "Refiner", targets: ["Refiner"]),
        .library(name: "Store", targets: ["Store"]),
        .library(name: "FieldContext", targets: ["FieldContext"]),
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
        .target(name: "Refiner", dependencies: ["GlideCore"]),
        .target(name: "Store", dependencies: ["GlideCore"]),
        .target(name: "FieldContext"),
        .executableTarget(name: "GlideBench", dependencies: ["GlideCore", "Recognizer", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "GlideCoreTests", dependencies: ["GlideCore"]),
        .testTarget(name: "HotkeyEngineTests", dependencies: ["HotkeyEngine"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
        .testTarget(name: "RefinerTests", dependencies: ["Refiner", "GlideCore"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", "GlideCore"]),
    ]
)
