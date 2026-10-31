import Foundation

struct ChatSelection: Hashable, Sendable {
    let serverID: String
    let sessionID: String
}

/// Cancellation alone doesn't stop detached filesystem/process work. Only the
/// latest ticket for the current context may publish into a visible view.
struct LatestRequest<Key: Equatable & Sendable>: Sendable {
    struct Ticket: Sendable { let key: Key; let generation: UUID }
    private var generation = UUID()
    mutating func invalidate() { generation = UUID() }
    mutating func begin(_ key: Key) -> Ticket {
        invalidate()
        return Ticket(key: key, generation: generation)
    }
    func accepts(_ ticket: Ticket, current: Key?) -> Bool {
        current == ticket.key && generation == ticket.generation
    }
}

struct EditorPresentation: Hashable, Sendable {
    let root: String
    let file: URL?

    static func relativePath(_ file: URL, root: String) -> String? {
        guard file.isFileURL else { return nil }
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

struct EditorLoadKey: Hashable, Sendable {
    let presentation: EditorPresentation
    let mode: String
    let revision: Int
}

/// Stream deltas are ephemeral in OpenCode V2; history contains text after
/// text.ended. Overlay by assistantMessageID + text ordinal, never an anonymous
/// extra bubble that a concurrent history reload can erase or duplicate.
struct ChatRenderStore: Sendable {
    private struct FragmentKey: Hashable, Sendable { let messageID: String; let ordinal: Int }
    private struct Fragment: Sendable {
        var text = ""
        var fullPrefix = false
        var ended = false
        var sequence = 0
    }
    private var histories: [ChatSelection: [JSON]] = [:]
    private var optimistic: [ChatSelection: [JSON]] = [:]
    private var fragments: [ChatSelection: [FragmentKey: Fragment]] = [:]
    private var order: [ChatSelection] = []
    private var nextSequence = 0

    mutating func select(_ key: ChatSelection) { touch(key) }
    mutating func appendUser(id: String, text: String, to key: ChatSelection) {
        optimistic[key, default: []].append(.object(["id": .string(id), "type": .string("user"), "text": .string(text)]))
    }
    mutating func load(_ raw: [JSON], for key: ChatSelection) {
        histories[key] = raw
        let ids = Set(raw.compactMap { $0["id"]?.string })
        optimistic[key] = optimistic[key]?.filter { !ids.contains($0["id"]?.string ?? "") }
        if var live = fragments[key] {
            for (fragmentKey, fragment) in live {
                guard let message = raw.first(where: { $0["id"]?.string == fragmentKey.messageID }) else { continue }
                if !fragment.fullPrefix,
                   message["time"]?["completed"]?.double != nil || message["finish"]?.string != nil || ChatFailure.parse(message["error"]) != nil {
                    live[fragmentKey] = nil
                    continue
                }
                let texts = (message["content"]?.array ?? []).filter { $0["type"]?.string == "text" }
                guard fragmentKey.ordinal < texts.count else { continue }
                let stored = texts[fragmentKey.ordinal]["text"]?.string ?? ""
                if (fragment.ended && stored == fragment.text) || (!fragment.fullPrefix && !stored.isEmpty) {
                    live[fragmentKey] = nil
                }
            }
            fragments[key] = live
        }
        touch(key)
    }

    mutating func consume(_ type: String, data: JSON, for key: ChatSelection) {
        guard let messageID = data["assistantMessageID"]?.string, !messageID.isEmpty,
              data["sessionID"]?.string.map({ $0 == key.sessionID }) ?? true,
              let value = data["ordinal"]?.double, value.isFinite, value >= 0, value <= 1000,
              value.rounded() == value else { return }
        let fragmentKey = FragmentKey(messageID: messageID, ordinal: Int(value))
        var fragment: Fragment
        if let existing = fragments[key]?[fragmentKey] { fragment = existing }
        else { nextSequence += 1; fragment = Fragment(sequence: nextSequence) }
        switch type {
        case "session.text.started": fragment = Fragment(text: "", fullPrefix: true, ended: false, sequence: fragment.sequence)
        case "session.text.delta":
            guard !fragment.ended else { return }
            fragment.text += data["delta"]?.string ?? ""
        case "session.text.ended":
            fragment.text = data["text"]?.string ?? fragment.text
            fragment.fullPrefix = true
            fragment.ended = true
        default: return
        }
        fragments[key, default: [:]][fragmentKey] = fragment
        let completed = (fragments[key] ?? [:]).filter { $0.value.ended }.sorted { $0.value.sequence < $1.value.sequence }
        for old in completed.prefix(max(0, completed.count - 16)) { fragments[key]?[old.key] = nil }
    }

    mutating func discardStream(for key: ChatSelection, messageID: String? = nil) {
        if let messageID { fragments[key] = fragments[key]?.filter { $0.key.messageID != messageID } }
        else { fragments[key] = nil }
    }
    mutating func discardStreams(serverID: String) {
        fragments = fragments.filter { $0.key.serverID != serverID }
    }
    mutating func finishBackground(for key: ChatSelection, messageID: String?) {
        // Recently viewed chats keep canonical ended text until history catches up,
        // so returning to a completed background reply doesn't flash an old transcript.
        if !order.contains(key) { discardStream(for: key, messageID: messageID) }
    }

    func isSynchronizing(_ key: ChatSelection) -> Bool {
        fragments[key]?.values.contains(where: { !$0.fullPrefix }) ?? false
    }

    func messages(for key: ChatSelection) -> [ChatMessage] {
        var raw = histories[key] ?? []
        let storedIDs = Set(raw.compactMap { $0["id"]?.string })
        raw += (optimistic[key] ?? []).filter { !storedIDs.contains($0["id"]?.string ?? "") }
        let live = (fragments[key] ?? [:]).sorted { $0.value.sequence < $1.value.sequence }
        for (id, fragment) in live where fragment.fullPrefix && !fragment.text.isEmpty {
            let index: Int
            if let existing = raw.firstIndex(where: { $0["id"]?.string == id.messageID }) { index = existing }
            else {
                index = raw.count
                raw.append(.object(["id": .string(id.messageID), "type": .string("assistant"), "content": .array([])]))
            }
            guard case .object(var message) = raw[index] else { continue }
            var content = message["content"]?.array ?? []
            var texts = content.indices.filter { content[$0]["type"]?.string == "text" }
            while texts.count <= id.ordinal {
                texts.append(content.count)
                content.append(.object(["type": .string("text"), "text": .string("")]))
            }
            guard case .object(var part) = content[texts[id.ordinal]] else { continue }
            let stored = part["text"]?.string ?? ""
            // A history snapshot may already contain the canonical text. Do not
            // replace it with an older prefix still waiting for its ended event.
            if fragment.ended || !stored.hasPrefix(fragment.text) { part["text"] = .string(fragment.text) }
            content[texts[id.ordinal]] = .object(part)
            message["content"] = .array(content)
            raw[index] = .object(message)
        }
        return ChatTranscript.history(raw)
    }

    private mutating func touch(_ key: ChatSelection) {
        order.removeAll { $0 == key }
        order.append(key)
        // Bound cached history, but retain in-flight fragments and unacknowledged
        // user submissions so switching cannot destroy text still being produced.
        while order.count > 8 {
            let old = order.removeFirst()
            histories[old] = nil
            fragments[old] = fragments[old]?.filter { !$0.value.ended }
        }
    }
}

enum TabOrdering {
    /// `tabs` with `url` inserted before `target` (nil or unknown = at the end), removing any
    /// earlier occurrence. Dropping a tab onto itself leaves the order unchanged.
    static func place(_ url: URL, in tabs: [URL], before target: URL?) -> [URL] {
        if target == url, tabs.contains(url) { return tabs }
        var result = tabs.filter { $0 != url }
        let index = target.flatMap { result.firstIndex(of: $0) } ?? result.count
        result.insert(url, at: index)
        return result
    }
}
