// swift-tools-version: 5.9
import PackageDescription

// MarkdownEngine — a TextKit-2 backed Markdown editor view for macOS.
//
// Embedders import `MarkdownEngine` and supply their own adapters that
// conform to the engine's service protocols (`WikiLinkResolver`,
// `EmbeddedImageProvider`, `SyntaxHighlighter`, `LatexRenderer`). The engine
// itself has zero external dependencies.
//
// Users who want turnkey adapters for the two highest-friction protocols
// (code-block styling/highlighting, LaTeX rendering) can additionally
// depend on the `MarkdownEngineCodeBlocks` and/or `MarkdownEngineLatex`
// products, which ship pre-built bridges backed by a bundled highlight.js
// and SwiftMath respectively. Both products are opt-in: the core
// `MarkdownEngine` library stays free of them at link time.
//
// `MarkdownEngineWebKit` is a third opt-in bridge: a WKWebView-backed
// `HTMLBlockRenderer` for raw HTML blocks. It adds no package dependency,
// only the system WebKit framework, which the core target never links.
let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "MarkdownEngineCodeBlocks", targets: ["MarkdownEngineCodeBlocks"]),
        .library(name: "MarkdownEngineLatex", targets: ["MarkdownEngineLatex"]),
        .library(name: "MarkdownEngineWebKit", targets: ["MarkdownEngineWebKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    ],
    targets: [
        .target(name: "MarkdownEngine"),
        .target(
            name: "MarkdownEngineCodeBlocks",
            dependencies: ["MarkdownEngine"],
            resources: [
                .copy("Resources/highlight.min.js"),
                .copy("Resources/highlight.js-LICENSE.txt"),
            ]
        ),
        .target(
            name: "MarkdownEngineLatex",
            dependencies: [
                "MarkdownEngine",
                .product(name: "SwiftMath", package: "SwiftMath"),
            ]
        ),
        .target(
            name: "MarkdownEngineWebKit",
            dependencies: ["MarkdownEngine"]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine"]
        ),
        .testTarget(
            name: "MarkdownEngineCodeBlocksTests",
            dependencies: ["MarkdownEngine", "MarkdownEngineCodeBlocks"]
        ),
        .testTarget(
            name: "MarkdownEngineLatexTests",
            dependencies: ["MarkdownEngine", "MarkdownEngineLatex"]
        ),
        .testTarget(
            name: "MarkdownEngineWebKitTests",
            dependencies: ["MarkdownEngine", "MarkdownEngineWebKit"]
        )
    ]
)
