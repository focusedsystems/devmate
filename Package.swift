// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevMate",
    platforms: [.macOS("27.0")],
    products: [
        // Models, provider capabilities, the repo registry and lane safety.
        .library(name: "DevMateCore", targets: ["DevMateCore"]),
        // Local Git operations.
        .library(name: "DevMateGit", targets: ["DevMateGit"]),
        // The GitHub provider, over the `gh` command.
        .library(name: "DevMateGitHub", targets: ["DevMateGitHub"]),
        // The Azure DevOps provider.
        .library(name: "DevMateAzure", targets: ["DevMateAzure"]),
        // The Development and Projects views.
        .library(name: "DevMateUI", targets: ["DevMateUI"]),
    ],
    dependencies: [
        // Issue bodies and comments.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .target(name: "DevMateCore"),
        .target(name: "DevMateGit", dependencies: ["DevMateCore"]),
        .target(name: "DevMateGitHub", dependencies: ["DevMateCore"]),
        .target(name: "DevMateAzure", dependencies: ["DevMateCore"]),
        .target(
            name: "DevMateUI",
            dependencies: ["DevMateCore", "DevMateGit", .product(name: "MarkdownUI", package: "swift-markdown-ui")]
        ),
        .testTarget(
            name: "DevMateCoreTests",
            dependencies: ["DevMateCore"],
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(name: "RunDetailSnapshot", dependencies: ["DevMateCore", "DevMateUI"]),
        .testTarget(name: "DevMateGitTests", dependencies: ["DevMateCore", "DevMateGit"]),
        .testTarget(name: "DevMateGitHubTests", dependencies: ["DevMateCore", "DevMateGitHub"]),
        .testTarget(name: "DevMateAzureTests", dependencies: ["DevMateCore", "DevMateAzure"]),
        .testTarget(name: "DevMateUITests", dependencies: ["DevMateCore", "DevMateGit", "DevMateUI"]),
    ],
    swiftLanguageModes: [.v6]
)
