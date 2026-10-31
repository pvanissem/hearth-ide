import Foundation

/// Forgets sandboxes the way the dashboard's "d" key does (`sandboxregistry.Remove`):
/// only devkcode's local metadata is deleted – never a process, repository or file.
/// devkcode has no CLI command for this, so the registries are edited directly,
/// keeping every other entry and field untouched.
enum RegistryCleanup {
    struct Result {
        var sandboxEntries = 0
        var webEntries = 0
    }

    static func forget(root: String, project: String?,
                       sandboxRegistry: URL = SandboxRegistry.defaultURL,
                       webRegistry: URL = WebSessionRegistry.defaultURL) throws -> Result {
        var result = Result()
        result.sandboxEntries = try removeEntries(at: sandboxRegistry, permissions: 0o644) { e in
            e["repoRoot"] as? String == root && (e["projectName"] as? String) == project
        }
        // Stopped web sessions for the same repo/project; a running one is stopped first by the caller.
        result.webEntries = try removeEntries(at: webRegistry, permissions: 0o600) { e in
            e["repoRoot"] as? String == root && (e["projectName"] as? String) == project
                && e["status"] as? String != "running"
        }
        return result
    }

    /// Removes matching entries from a `{version, entries: [...]}` registry file.
    private static func removeEntries(at url: URL, permissions: Int, where match: ([String: Any]) -> Bool) throws -> Int {
        guard let data = try? Data(contentsOf: url),
              var file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = file["entries"] as? [[String: Any]] else { return 0 }
        let kept = entries.filter { !match($0) }
        let removed = entries.count - kept.count
        guard removed > 0 else { return 0 }
        file["entries"] = kept
        let out = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        // Write next to the original and swap in, so a concurrent reader never sees a partial file.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).hearth-tmp")
        try out.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return removed
    }
}
