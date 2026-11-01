import SwiftUI
import AppKit

/// Pipeline graph (GitLab stages, GitHub job groups): one column per stage, job nodes, connectors between stages.
struct PipelineGraph: View {
    @Environment(\.textScale) private var scale
    let jobs: [CIJob]
    var large = false
    let onSelect: (CIJob) -> Void
    var onRetry: ((CIJob) -> Void)?
    var onPlay: ((CIJob) -> Void)?
    private let hovered = State(initialValue: Int?.none)

    private struct NodeKey: Hashable { let stage: Int; let job: Int }

    private struct NodeFrames: PreferenceKey {
        static let defaultValue: [NodeKey: Anchor<CGRect>] = [:]
        static func reduce(value: inout [NodeKey: Anchor<CGRect>], nextValue: () -> [NodeKey: Anchor<CGRect>]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private var stages: [(name: String, jobs: [CIJob])] {
        var order: [String] = []
        var map: [String: [CIJob]] = [:]
        for j in jobs {
            if map[j.stage] == nil { order.append(j.stage) }
            map[j.stage, default: []].append(j)
        }
        return order.map { ($0, map[$0]!) }
    }

    private var columnGap: CGFloat { (large ? 56 : 40) * scale }

    var body: some View {
        let stages = self.stages
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: columnGap) {
                ForEach(Array(stages.enumerated()), id: \.offset) { si, stage in
                    VStack(alignment: .leading, spacing: 8 * scale) {
                        HStack(spacing: 4) {
                            Image(systemName: CIStatus.symbol(stageStatus(stage.jobs)))
                                .foregroundStyle(Self.color(stageStatus(stage.jobs)))
                            Text(stage.name).scaledFont(.caption, bold: true).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                        ForEach(Array(stage.jobs.enumerated()), id: \.element.id) { ji, job in
                            node(job)
                                .anchorPreference(key: NodeFrames.self, value: .bounds) { [NodeKey(stage: si, job: ji): $0] }
                        }
                    }
                }
            }
            .padding(14)
            .overlayPreferenceValue(NodeFrames.self) { anchors in
                GeometryReader { geo in
                    connectors(stages: stages, anchors: anchors, geo: geo)
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Nodes

    private func node(_ job: CIJob) -> some View {
        let c = Self.color(job.status)
        return HStack(spacing: 6) {
            Image(systemName: CIStatus.symbol(job.status)).foregroundStyle(c)
                .symbolEffect(.pulse, isActive: job.status == "running")
            Text(job.name).scaledFont(large ? .body : .callout).lineLimit(1)
            if job.allowFailure && job.status == "failed" {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).scaledFont(.caption2)
            }
            Spacer(minLength: 4)
            actionButton(job)
        }
        .padding(.horizontal, 10)
        // Fixed height so nodes with and without action buttons line up (straight connectors).
        .frame(minWidth: (large ? 170 : 130) * scale, minHeight: 30 * scale, maxHeight: 30 * scale, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(c.opacity(0.7), lineWidth: 1.5))
        .contentShape(Capsule())
        .onTapGesture { onSelect(job) }
        .onHover { inside in
            hovered.wrappedValue = inside ? job.id : (hovered.wrappedValue == job.id ? nil : hovered.wrappedValue)
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(tooltip(job))
        .contextMenu {
            Button { onSelect(job) } label: { Label("Log anzeigen", systemImage: "doc.text") }
            if let url = job.webURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Im Browser öffnen", systemImage: "arrow.up.forward.square") }
            }
            if let onPlay, job.status == "manual" {
                Button { onPlay(job) } label: { Label("Manuell starten …", systemImage: "play.fill") }
            }
            if let onRetry, Self.retryable(job) {
                Button { onRetry(job) } label: { Label("Job wiederholen", systemImage: "arrow.clockwise") }
            }
        }
    }

    static func retryable(_ job: CIJob) -> Bool { ["failed", "canceled", "success"].contains(job.status) }

    /// ▶︎ for manual jobs, ↻ for failed/canceled ones (and on hover for successful ones).
    @ViewBuilder
    private func actionButton(_ job: CIJob) -> some View {
        if job.status == "manual", let onPlay {
            CircleAction(symbol: "play.fill", tint: .purple, help: "Manuellen Job starten") { onPlay(job) }
        } else if let onRetry, Self.retryable(job),
                  job.status != "success" || hovered.wrappedValue == job.id {
            CircleAction(symbol: "arrow.clockwise", tint: job.status == "success" ? .secondary : .orange,
                         help: "Job wiederholen") { onRetry(job) }
        }
    }

    private func tooltip(_ job: CIJob) -> String {
        var t = "\(job.name) – \(CIStatus.label(job.status))"
        if let d = job.duration { t += d < 60 ? " · \(Int(d)) s" : " · \(Int(d) / 60) min \(Int(d) % 60) s" }
        return t + "\nKlicken für das Log"
    }

    /// Worst status wins, like GitLab's stage badge.
    private func stageStatus(_ jobs: [CIJob]) -> String {
        let s = Set(jobs.map(\.status))
        for candidate in ["failed", "running", "pending", "created", "canceled", "manual", "skipped"] where s.contains(candidate) {
            if candidate == "failed", jobs.allSatisfy({ $0.status != "failed" || $0.allowFailure }) { continue }
            return candidate
        }
        return s.contains("success") ? "success" : (s.first ?? "unknown")
    }

    static func color(_ s: String) -> Color {
        switch s {
        case "success": .green
        case "failed": .red
        case "running": .blue
        case "canceled", "canceling", "skipped": .secondary
        case "manual": .purple
        default: .orange
        }
    }

    // MARK: Connectors

    /// Each job joins a vertical bus halfway to the next stage, which fans out to that stage's jobs.
    private func connectors(stages: [(name: String, jobs: [CIJob])], anchors: [NodeKey: Anchor<CGRect>], geo: GeometryProxy) -> some View {
        Path { path in
            guard stages.count > 1 else { return }
            for si in 0..<(stages.count - 1) {
                let left = stages[si].jobs.indices.compactMap { anchors[NodeKey(stage: si, job: $0)].map { geo[$0] } }
                let right = stages[si + 1].jobs.indices.compactMap { anchors[NodeKey(stage: si + 1, job: $0)].map { geo[$0] } }
                guard let maxLeft = left.map(\.maxX).max(), let minRight = right.map(\.minX).min() else { continue }
                let busX = (maxLeft + minRight) / 2
                let ys = (left + right).map(\.midY)
                for r in left {
                    path.move(to: CGPoint(x: r.maxX, y: r.midY))
                    path.addLine(to: CGPoint(x: busX, y: r.midY))
                }
                path.move(to: CGPoint(x: busX, y: ys.min()!))
                path.addLine(to: CGPoint(x: busX, y: ys.max()!))
                for r in right {
                    path.move(to: CGPoint(x: busX, y: r.midY))
                    path.addLine(to: CGPoint(x: r.minX, y: r.midY))
                }
            }
        }
        .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

/// Small round action button used on pipeline nodes and job rows.
struct CircleAction: View {
    @Environment(\.textScale) private var scale
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void
    private let hovering = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9 * scale, weight: .bold))
                .foregroundStyle(hovering.wrappedValue ? .white : tint)
                .frame(width: 20 * scale, height: 20 * scale)
                .background(hovering.wrappedValue ? tint : tint.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
        .help(help)
    }
}
