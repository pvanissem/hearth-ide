import SwiftUI
import WebKit

struct ArchitectureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let root: String

    private let diagrams = State(initialValue: [MermaidDiagram]?.none)
    private let selectedID = State(initialValue: String?.none)
    private let showSource = State(initialValue: false)
    private let renderError = State(initialValue: String?.none)

    static let generatePrompt = """
    Erstelle oder aktualisiere `docs/architecture.md` mit einer kurzen Architekturbeschreibung dieses \
    Repositories und mindestens einem Mermaid-Diagramm (```mermaid, z. B. flowchart LR) mit den \
    wichtigsten Komponenten, Schnittstellen und Datenflüssen. Halte die Diagramme lesbar (max. ~20 Knoten) \
    und prüfe, dass die Mermaid-Syntax gültig ist.
    """

    var body: some View {
        Group {
            if let list = diagrams.wrappedValue {
                if list.isEmpty { empty } else { content(list) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(root)#\(model.workspaceRevision)") {
            let found = await MermaidScanner.scan(root: root)
            diagrams.wrappedValue = found
            if selectedID.wrappedValue == nil || !found.contains(where: { $0.id == selectedID.wrappedValue }) {
                selectedID.wrappedValue = found.first?.id
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Keine Diagramme", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Gesucht wird nach ```mermaid-Blöcken in Markdown sowie .mmd-Dateien.")
        } actions: {
            Button("Architektur vom Agenten erzeugen lassen") { model.ask(Self.generatePrompt) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func content(_ list: [MermaidDiagram]) -> some View {
        let current = list.first { $0.id == selectedID.wrappedValue } ?? list[0]
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(groupedByFile(list), id: \.0) { file, items in
                        Section(file) {
                            ForEach(items) { d in
                                Button { selectedID.wrappedValue = d.id } label: {
                                    if d.id == current.id { Label(label(d), systemImage: "checkmark") } else { Text(label(d)) }
                                }
                            }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(current.title).font(.callout.bold()).lineLimit(1)
                        Text("\(current.file):\(current.line)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                Text("\(list.count)").font(.caption2).padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                Toggle(isOn: showSource.projectedValue) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .toggleStyle(.button).help("Quelltext anzeigen")
                Button {
                    model.openPreview(URL(fileURLWithPath: root).appendingPathComponent(current.file), mode: .file, line: current.line)
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help("Quelle in der Vorschau öffnen")
                Menu {
                    Button("Neues Architektur-Diagramm erzeugen lassen") { model.ask(Self.generatePrompt) }
                    Button("Dieses Diagramm aktualisieren lassen") {
                        model.ask("Aktualisiere das Mermaid-Diagramm „\(current.title)“ in `\(current.file)` (ab Zeile \(current.line)) so, dass es dem aktuellen Code entspricht. Behalte die Syntax gültig.")
                    }
                    if renderError.wrappedValue != nil {
                        Button("Syntaxfehler vom Agenten beheben lassen") {
                            model.ask("Das Mermaid-Diagramm in `\(current.file)` (ab Zeile \(current.line)) lässt sich nicht rendern: \(renderError.wrappedValue ?? ""). Bitte korrigiere die Syntax.")
                        }
                    }
                } label: { Image(systemName: "wand.and.stars") }
                    .menuStyle(.borderlessButton).fixedSize().help("Agent-Aktionen")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            if showSource.wrappedValue {
                VSplitView {
                    canvas(current).frame(minHeight: 120)
                    CodeText(text: current.source, diff: false).frame(minHeight: 80)
                }
            } else {
                canvas(current)
            }
        }
    }

    private func canvas(_ d: MermaidDiagram) -> some View {
        MermaidCanvas(source: d.source, title: d.title, onOpenWindow: { openWindow(value: d) },
                      onError: { renderError.wrappedValue = $0 })
            .id(d.id)
            .onHover { model.hoveringDiagram = $0 }
    }

    private func label(_ d: MermaidDiagram) -> String { "\(d.title) · \(d.kind)" }

    private func groupedByFile(_ list: [MermaidDiagram]) -> [(String, [MermaidDiagram])] {
        var order: [String] = []
        var map: [String: [MermaidDiagram]] = [:]
        for d in list {
            if map[d.file] == nil { order.append(d.file) }
            map[d.file, default: []].append(d)
        }
        return order.map { ($0, map[$0]!) }
    }
}

enum MermaidAsset {
    static let fileName = "mermaid.min.js"

    /// In the app bundle under Resources; during `swift run` from the repo's Resources folder.
    static let url: URL? = {
        if let u = Bundle.main.resourceURL?.appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: u.path) { return u }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Resources/\(fileName)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }()

}
