// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hearth",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Embedded terminal emulator (VT100/xterm, PTY) for the Terminal pane.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // GitHub-flavoured Markdown parser (cmark-gfm); rendered by MarkdownView.swift.
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Hearth",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/Hearth"
        ),
        .testTarget(
            name: "HearthTests",
            dependencies: ["Hearth"],
            path: "Tests/HearthTests"
        ),
    ]
)
