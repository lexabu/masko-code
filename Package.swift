// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "masko-code",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "masko-code",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources",
            exclude: ["masko-desktop.entitlements"],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Images"),
                .copy("Resources/Defaults"),
                .copy("Resources/Extensions")
            ]
        )
    ]
)
