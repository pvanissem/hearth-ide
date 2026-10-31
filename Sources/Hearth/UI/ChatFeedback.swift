import SwiftUI
import AppKit

/// Indeterminate activity, not a fabricated percentage or a view of hidden reasoning.
struct AgentWorkingIndicator: View {
    @Environment(\.textScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animates = true
    var label = "Agent arbeitet …"

    var body: some View {
        let moving = animates && !reduceMotion
        HStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 0.1, paused: !moving)) { context in
                let phase = moving ? context.date.timeIntervalSinceReferenceDate * 5 : 0
                HStack(spacing: 2 * scale) {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(moving ? 0.2 + 0.8 * max(0, sin(phase - Double(i) * 0.55)) : 0.6))
                            .frame(width: 4 * scale, height: 10 * scale)
                    }
                }
            }
            .frame(width: 46 * scale, height: 12 * scale)
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

struct ChatFailureCard: View {
    let failure: ChatFailure
    var title: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(title ?? failure.title).scaledFont(.callout, bold: true)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failure.detail, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Vollständigen Fehler kopieren")
                    .accessibilityLabel("Vollständigen Fehler kopieren")
            }
            if failure.code != nil || failure.status != nil {
                HStack(spacing: 8) {
                    if let code = failure.code {
                        Text(code).scaledFont(.caption, bold: true, mono: true).foregroundStyle(.red)
                    }
                    if let status = failure.status {
                        Text("HTTP \(status)").scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                    }
                }
            }
            Text(failure.message).scaledFont(.callout)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if failure.detail != failure.message {
                DisclosureGroup("Technische Details") {
                    Text(failure.detail).scaledFont(.caption, mono: true)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                .scaledFont(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.25)))
    }
}
