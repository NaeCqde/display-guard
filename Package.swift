// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "display-guard",
    platforms: [.macOS(.v13)],
    dependencies: [
        // TOML parser (Codable based, TOML 1.1)
        .package(url: "https://github.com/dduan/TOMLDecoder", .upToNextMinor(from: "0.4.5")),
        // Interactive prompts (the multiple choice one: space selects, return goes on) for `setup`
        .package(url: "https://github.com/tuist/Noora", .upToNextMinor(from: "0.57.7")),
    ],
    targets: [
        .executableTarget(
            name: "display-guard",
            dependencies: [
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                .product(name: "Noora", package: "Noora"),
            ],
            path: "Sources/display-guard"
        )
    ]
)
