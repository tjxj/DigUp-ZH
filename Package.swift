// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DigUp-ZH",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "digup", targets: ["digup"]),
        .executable(name: "DigUpApp", targets: ["DigUpApp"]),
        .library(name: "DigUpKit", targets: ["DigUpKit"]),
    ],
    dependencies: [
    ],
    targets: [
        // The engine: crawler, extractors, index store, the embedder interface and worker client, search. No UI.
        .target(name: "DigUpKit"),
        // llama.cpp (scripts/build-llama.sh builds it into Vendor/llama) and Qwen3-VL-Embedding-2B on it.
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        .target(
            name: "LlamaRuntime",
            dependencies: ["CLlama", "DigUpKit"],
            linkerSettings: [.unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"])]
        ),
        // Developer CLI: estimate / index / search / status / eval. Doubles as the eval harness, and the app runs it as
        // its indexing helper and its query encoder.
        .executableTarget(name: "digup", dependencies: ["DigUpKit", "LlamaRuntime"]),
        // The menubar + hotkey app. build.sh wraps it into build.noindex/DigUp.app. (The product can't be called
        // "DigUp": on a case-insensitive disk it would collide with the `digup` CLI binary.)
        .executableTarget(
            name: "DigUpApp",
            dependencies: ["DigUpKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "DigUpKitTests", dependencies: ["DigUpKit"]),
        .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"], exclude: ["Reference"]),
    ]
)
