import SwiftUI
import AppKit

/// Developer aid: `HEARTH_SNAPSHOT=<dir> Hearth` renders key views offscreen
/// with live data to PNG files and exits. Needs no screen-recording permission.
@MainActor
enum Snapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT"].map { URL(fileURLWithPath: $0) }
    }

    static func run(model: AppModel) {
        guard let dir = directory else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Give the registry poll and server connections time to load.
            try? await Task.sleep(for: .seconds(4))
            await model.loadProfiles()
            if let z = ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_ZOOM"].flatMap(Double.init) {
                model.textScales = Dictionary(uniqueKeysWithValues: TextArea.allCases.map { ($0.rawValue, z) })
            }
            if let raw = ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_DOCK_BOTTOM"], let tab = InspectorTab(rawValue: raw) {
                model.addPane(tab, atWindowEdge: .windowBottom)
            }
            // Comma-separated paths open as editor tabs; the last one is active.
            if let files = ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_PREVIEW"] {
                for file in files.split(separator: ",") { model.openPreview(URL(fileURLWithPath: String(file)), mode: .file, line: nil) }
            }
            if ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_SPLIT_EDITOR"] != nil,
               let p = model.paneTree.panes.first(where: { $0.tab == .preview }) {
                model.splitEditor(p.id, url: URL(fileURLWithPath: "/tmp/hearth-snapshot/Package.swift"))
            }
            if let first = model.inbox.first { model.select(first) }
            try? await Task.sleep(for: .seconds(2))

            if let list = ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_TABBENCH"] {
                await benchmarkTabs(model: model, files: list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }, out: dir)
                exit(0)
            }
            var views: [(String, AnyView, CGSize)] = [
                ("main", AnyView(ContentView()), CGSize(width: 1400, height: 860)),
                ("start-sheet", AnyView(StartSandboxSheet(request: .init(root: model.entries.first?.repoRoot))), CGSize(width: 520, height: 640)),
                ("settings", AnyView(SettingsView()), CGSize(width: 680, height: 500)),
                ("welcome", AnyView(WelcomeView()), CGSize(width: 600, height: 560)),
                ("pipeline-graph", AnyView(PipelineGraph(jobs: Self.sampleJobs, onSelect: { _ in }, onRetry: { _ in }, onPlay: { _ in })), CGSize(width: 860, height: 300)),
            ]
            if let root = ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_BUILD_ROOT"] {
                views.append(("build-wide", AnyView(BuildDeployView(root: root, preloaded: BuildDetector.scan(root: root))), CGSize(width: 1100, height: 520)))
                views.append(("build-narrow", AnyView(BuildDeployView(root: root, preloaded: BuildDetector.scan(root: root))), CGSize(width: 620, height: 640)))
            }
            if let path = ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_MARKDOWN"],
               let md = try? String(contentsOfFile: path, encoding: .utf8) {
                views.append(("markdown", AnyView(ScrollView { MarkdownBlocks(text: md).environment(\.markdownMono, true).padding(16) }), CGSize(width: 760, height: 900)))
            }
            for (name, view, size) in views {
                for dark in [false, true] {
                    render(view.environment(model), size: size, dark: dark,
                           to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
            }
            exit(0)
        }
    }

    /// Developer aid: switches editor tabs in the full window like a click does and
    /// records how long SwiftUI/AppKit need until the frame is laid out and drawn.
    static func benchmarkTabs(model: AppModel, files: [URL], out: URL) async {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1500, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ContentView().environment(model).frame(width: 1500, height: 900))
        window.contentView = host
        window.orderFrontRegardless()
        for f in files { model.openPreview(f) }
        try? await Task.sleep(for: .seconds(2))
        var lines: [String] = ["workspace: \(model.workspaceRoot ?? "-") panes: \(describe(model.paneTree))"]
        var samples: [String: [Double]] = [:]
        for round in 0..<(Int(ProcessInfo.processInfo.environment["HEARTH_TABBENCH_ROUNDS"] ?? "") ?? 6) {
            for f in files {
                let start = CFAbsoluteTimeGetCurrent()
                model.openPreview(f)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let sync = (CFAbsoluteTimeGetCurrent() - start) * 1000
                // Let queued main-thread work (restore, async colouring, tasks) run.
                try? await Task.sleep(for: .milliseconds(1))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let settled = (CFAbsoluteTimeGetCurrent() - start) * 1000
                if round > 0 { samples[f.lastPathComponent, default: []].append(sync); samples[f.lastPathComponent + " (settled)", default: []].append(settled) }
                try? await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.environment["HEARTH_TABBENCH_ROUNDS"] == nil ? 300 : 5))
            }
        }
        for (k, v) in samples.sorted(by: { $0.key < $1.key }) {
            let sorted = v.sorted()
            lines.append(String(format: "%@: median %.1f ms, max %.1f ms", k, sorted[sorted.count / 2], sorted.last ?? 0))
        }
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("tabbench.txt"), atomically: true, encoding: .utf8)
    }

    static func describe(_ n: PaneNode) -> String {
        switch n {
        case .leaf(let p): return p.tab.rawValue
        case .split(_, let a, let c): return (a == .vertical ? "V" : "H") + "(" + c.map(describe).joined(separator: ",") + ")"
        }
    }

    /// Fixed sample pipeline for rendering the graph without GitLab access.
    static var sampleJobs: [CIJob] {
        let raw: [(String, String, String, Bool)] = [
            ("validate", "lint", "success", false), ("validate", "unit-tests", "success", false),
            ("validate", "sonar", "failed", true), ("build", "build-macos", "success", false),
            ("build", "build-linux", "running", false), ("publish", "upload-nexus", "pending", false),
            ("deploy", "pages", "manual", false),
        ]
        return raw.enumerated().compactMap { i, j in
            CIJob(json: JSON.parse(Data(#"{"id":\#(i + 1),"stage":"\#(j.0)","name":"\#(j.1)","status":"\#(j.2)","duration":\#(30 + i * 17),"allow_failure":\#(j.3)}"#.utf8))!)
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        // Render the layer tree (what the compositor gets); PDF output skipped
        // layer-drawn content and floating subviews.
        let scale: CGFloat = 2
        guard let layer = host.layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        window.appearance?.performAsCurrentDrawingAppearance {
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        window.orderOut(nil)
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
