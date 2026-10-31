import SwiftUI

/// Native version of devkcode's /copilot-usage TUI dialog.
struct CopilotUsageView: View {
    @Environment(\.dismiss) private var dismiss
    let usage: CopilotUsage

    private static func fmt(_ n: Double) -> String {
        n.formatted(.number.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Copilot AI-Credits", systemImage: "gauge.with.dots.needle.67percent").font(.title2.bold())
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            GroupBox("GitHub – gesamte Copilot-Nutzung (abgerechnet)") {
                if let f = usage.fraction, let used = usage.used, let total = usage.entitlement {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: "%.1f %%", f * 100)).font(.system(size: 28, weight: .bold).monospacedDigit())
                                .foregroundStyle(f >= 1 ? .red : (f >= 0.8 ? .orange : .primary))
                            Text("\(Self.fmt(used)) von \(Self.fmt(total)) Credits").foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "$%.2f", used / 100)).font(.title3.monospacedDigit())
                        }
                        ProgressView(value: min(f, 1)).tint(f >= 1 ? .red : (f >= 0.8 ? .orange : .accentColor))
                        HStack {
                            if let r = usage.remaining {
                                Text("Verbleibend: \(Self.fmt(r)) (\(String(format: "$%.2f", r / 100)))")
                            }
                            Spacer()
                            if let reset = usage.reset { Text("Zurückgesetzt am \(reset)") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if f >= 1 {
                            Text(usage.overage == true ? "Weitere Nutzung wird als Overage abgerechnet." : "Copilot-Anfragen können blockiert werden.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(6)
                } else {
                    Text("GitHub-Zahlen nicht verfügbar: \(usage.githubError ?? "unbekannt")").foregroundStyle(.secondary).padding(6)
                }
            }

            GroupBox("OpenCode diesen Monat (Sessions auf diesem Rechner, geschätzt)") {
                if usage.models.isEmpty {
                    Text(usage.statsError.map { "Statistik nicht verfügbar: \($0)" } ?? "Keine Copilot-Nutzung.")
                        .foregroundStyle(.secondary).padding(6)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("Modell").bold()
                            Text("Credits").bold().gridColumnAlignment(.trailing)
                            Text("Kosten").bold().gridColumnAlignment(.trailing)
                            Text("Schritte").bold().gridColumnAlignment(.trailing)
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(usage.models, id: \.name) { m in
                            GridRow {
                                Text(m.name).font(.callout.monospaced())
                                Text(Self.fmt(m.cost * 100)).monospacedDigit()
                                Text(String(format: "$%.2f", m.cost)).monospacedDigit()
                                Text("\(m.steps)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        let total = usage.models.reduce(0) { $0 + $1.cost }
                        GridRow {
                            Text("Summe").bold()
                            Text(Self.fmt(total * 100)).bold().monospacedDigit()
                            Text(String(format: "$%.2f", total)).bold().monospacedDigit()
                            Text("")
                        }
                    }
                    .padding(6)
                }
            }

            Text("Nicht in der OpenCode-Tabelle: gelöschte Sessions, andere Rechner, Copilot in IDEs oder auf github.com. Abgerechnet wird die GitHub-Zahl.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 560)
    }
}
