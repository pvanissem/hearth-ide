import Foundation
import Darwin

/// Git network actions are explicit UI actions executed in Hearth's nono sandbox, never by an
/// agent and never on the host. Fetch and clone may use SSH keys and the keychain; the
/// fast-forward after a fetch runs without them (S1 in docs/review-security-architecture.md).
extension AppModel {
    func networkGit(_ operation: SandboxGitOperation, in directory: String) async -> Git.OpResult {
        do {
            let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
            guard let overrides = Git.networkSandboxOverrides(in: root.path) else {
                throw SandboxCommandError("Git-Konfiguration konnte nicht sicher gelesen werden.")
            }
            let purpose: SandboxPurpose = operation.needsNetwork ? .gitNetwork : .gitLocal
            guard let runner = runner(root: root.path, purpose: purpose) else {
                throw SandboxCommandError("nono wurde nicht gefunden. Kein Host-Fallback.")
            }
            return await SandboxGitRunner(runner: runner, root: root,
                                          repoOverrides: operation.needsNetwork ? overrides : []).run(operation)
        } catch { return Git.OpResult(ok: false, output: error.localizedDescription) }
    }

    /// Pull = fetch in the network sandbox, then fast-forward in a sandbox without keys.
    func pull(in directory: String) async -> Git.OpResult {
        let fetched = await networkGit(.fetchUpstream, in: directory)
        guard fetched.ok else { return fetched }
        let merged = await networkGit(.fastForward, in: directory)
        return Git.OpResult(ok: merged.ok, output: [fetched.output, merged.output].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    func cloneRepository(_ remote: String, to destination: URL,
                         progress: @escaping @Sendable (String, Double?) -> Void) async -> Git.OpResult {
        do {
            guard SandboxGitOperation.validCloneURL(remote), destination.isFileURL else {
                throw SandboxCommandError("Keine gültige HTTPS-/SSH-Git-URL.")
            }
            let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
            let name = destination.lastPathComponent
            guard parent.path == home.path || parent.path.hasPrefix(home.path + "/"),
                  !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw SandboxCommandError("Der Zielordner muss unterhalb deines Benutzerordners liegen.")
            }
            let root = parent.appendingPathComponent(name)
            if !workspace.cloneDirectories.contains(root.path) {
                // Atomic reservation: do not adopt an existing directory, including empty ones/symlinks.
                guard mkdir(root.path, 0o700) == 0 else {
                    throw SandboxCommandError("Zielordner konnte nicht neu angelegt werden (existiert bereits oder keine Berechtigung).")
                }
                workspace.cloneDirectories.insert(root.path)
            }
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                  root.resolvingSymlinksInPath().path == root.path else {
                throw SandboxCommandError("Der reservierte Zielordner ist nicht mehr leer oder wurde durch einen Symlink ersetzt. Kein Überschreiben.")
            }
            progress("Starte Sandbox im neuen Zielordner …", nil)
            guard let runner = runner(root: root.path, purpose: .gitNetwork) else {
                throw SandboxCommandError("nono wurde nicht gefunden. Kein Host-Fallback.")
            }
            let result = await SandboxGitRunner(runner: runner, root: root).run(.clone(remote), progress: progress)
            if result.ok {
                workspace.cloneDirectories.remove(root.path)
                workspace.revision += 1
            }
            return result
        } catch {
            return Git.OpResult(ok: false, output: error.localizedDescription + "\nKeine ungeschützte Git-Ausführung; vorhandene Daten werden nicht gelöscht.")
        }
    }
}
