import SwiftUI

/// Renders an agent question (OpenCode form) as an inline card, like the
/// "Blocker (Needs Input)" box in the mockup.
struct FormCard: View {
    @Environment(AppModel.self) private var model
    let form: FormRequest
    private let answers: State<[String: FormValue]>
    private let sending = State(initialValue: false)

    init(form: FormRequest) {
        self.form = form
        var initial: [String: FormValue] = [:]
        for f in form.fields { if let d = f.defaultValue { initial[f.key] = d } }
        answers = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Blocker – der Agent braucht deine Entscheidung", systemImage: "questionmark.bubble.fill")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text(form.title).font(.headline)
            ForEach(form.visibleFields(answers.wrappedValue)) { field in
                FieldView(field: field, value: binding(field.key))
            }
            HStack {
                Button("Antworten") {
                    sending.wrappedValue = true
                    Task {
                        await model.reply(form, answers: answers.wrappedValue)
                        sending.wrappedValue = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending.wrappedValue || form.missingRequired(answers.wrappedValue))
                Button("Abbrechen", role: .cancel) { Task { await model.cancel(form) } }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange))
    }

    private func binding(_ key: String) -> Binding<FormValue?> {
        Binding(get: { answers.wrappedValue[key] }, set: { answers.wrappedValue[key] = $0 })
    }
}

private struct FieldView: View {
    let field: FormRequest.Field
    @Binding var value: FormValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.kind != .boolean {
                Text(field.title + (field.required ? " *" : "")).font(.callout.bold())
            }
            if let d = field.description { Text(d).font(.caption).foregroundStyle(.secondary) }
            input
        }
    }

    @ViewBuilder
    private var input: some View {
        switch field.kind {
        case .string(let options, let placeholder) where options.isEmpty:
            TextField(placeholder ?? "", text: stringBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
        case .string(let options, _):
            OptionList(options: options, selected: Set([stringBinding.wrappedValue])) { v in
                value = .string(v)
            }
        case .number(let integer):
            TextField(integer ? "Ganzzahl" : "Zahl", text: Binding(
                get: { if case .number(let n)? = value { integer ? String(Int(n)) : String(n) } else { "" } },
                set: { value = Double($0.replacingOccurrences(of: ",", with: ".")).map(FormValue.number) }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
        case .boolean:
            Toggle(field.title, isOn: Binding(
                get: { if case .bool(let b)? = value { b } else { false } },
                set: { value = .bool($0) }))
        case .multiselect(let options, let maxItems, _):
            let current = listValue
            OptionList(options: options, selected: Set(current), multi: maxItems != 1) { v in
                if maxItems == 1 {
                    value = .list([v])
                } else if current.contains(v) {
                    value = .list(current.filter { $0 != v })
                } else if maxItems.map({ current.count < $0 }) ?? true {
                    value = .list(current + [v])
                }
            }
        case .external(let url):
            if let u = URL(string: url) { Link("Im Browser öffnen", destination: u) }
        case .unknown:
            Text("Nicht unterstützter Feldtyp").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stringBinding: Binding<String> {
        Binding(get: { if case .string(let s)? = value { s } else { "" } }, set: { value = .string($0) })
    }

    private var listValue: [String] {
        if case .list(let l)? = value { return l }
        return []
    }
}

private struct OptionList: View {
    let options: [FormRequest.Option]
    let selected: Set<String>
    var multi = false
    let toggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button { toggle(option.value) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(selected.contains(option.value)))
                            .foregroundStyle(selected.contains(option.value) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                            if let d = option.description {
                                Text(d).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(selected.contains(option.value) ? Color.accentColor.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(_ on: Bool) -> String {
        multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
    }
}
