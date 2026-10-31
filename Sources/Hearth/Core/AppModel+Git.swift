import Foundation
import Darwin

extension AppModel {
    /// Fetch/pull are explicit UI actions executed in a sandbox (a running devkcode
    /// server, else Hearth's nono sandbox), not by an agent or the local host Git dispatcher.
    func networkGit(_ operation: SandboxGitOperation, in directory: String) async -> Git.OpResult {
        do {
            let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
            let client = try await prepareGitSandbox(root: root)
            return await SandboxGitRunner(client: client, root: root).run(operation)
        } catch { return Git.OpResult(ok: false, output: error.localizedDescription) }
    }

    func cloneRepository(_ remote: String, to destination: URL, profile: String?,
                         progress: @escaping @Sendable (String, Double?) -> Void) async -> Git.OpResult {
        do {
            guard SandboxGitOperation.validCloneURL(remote), destination.isFileURL else {
                throw SandboxGitRunner.Failure("Keine gültige HTTPS-/SSH-Git-URL.")
            }
            let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
            let name = destination.lastPathComponent
            guard parent.path == home.path || parent.path.hasPrefix(home.path + "/"),
                  !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw SandboxGitRunner.Failure("Der Zielordner muss unterhalb deines Benutzerordners liegen.")
            }
            let root = parent.appendingPathComponent(name)
            if !cloneDirectories.contains(root.path) {
                // Atomic reservation: do not adopt an existing directory, including empty ones/symlinks.
                guard mkdir(root.path, 0o700) == 0 else {
                    throw SandboxGitRunner.Failure("Zielordner konnte nicht neu angelegt werden (existiert bereits oder keine Berechtigung).")
                }
                cloneDirectories.insert(root.path)
            }
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                  root.resolvingSymlinksInPath().path == root.path else {
                throw SandboxGitRunner.Failure("Der reservierte Zielordner ist nicht mehr leer oder wurde durch einen Symlink ersetzt. Kein Überschreiben.")
            }
            progress("Starte Sandbox im neuen Zielordner …", nil)
            let client = try await prepareGitSandbox(root: root, profile: profile)
            let result = await SandboxGitRunner(client: client, root: root).run(.clone(remote), progress: progress)
            if result.ok {
                cloneDirectories.remove(root.path)
                // Only this new server's empty location is reloaded to discover its new VCS.
                if let server = client as? OpenCodeClient {
                    try? await server.send("POST", "/api/location/reload", session: GitLabTransport.session)
                }
                workspaceRevision += 1
                refreshRegistry()
                if let connection = servers.values.first(where: { sameGitRoot($0.entry.repoRoot, root.path) }) {
                    try? await connection.reload()
                    if let newest = connection.sessions.values.max(by: { $0.updated < $1.updated }) { select(newest) }
                    else { selectSandbox(connection.id) }
                }
            }
            return result
        } catch {
            return Git.OpResult(ok: false, output: error.localizedDescription + "\nKeine ungeschützte Git-Ausführung; vorhandene Daten werden nicht gelöscht.")
        }
    }

    /// Reuse a running registry entry without `devkcode web` (which creates an
    /// empty chat session on each invocation). Start only when genuinely missing.
    private func prepareGitSandbox(root: URL, profile: String? = nil) async throws -> any SandboxShellAPI {
        try Task.checkCancellation()
        let saved = try WebSessionRegistry.load().first { sameGitRoot($0.repoRoot, root.path) }
        if let saved, WebSessionRegistry.isAlive(saved), let url = saved.baseURL, let password = saved.password {
            guard SandboxGitRunner.isLocalServer(url) else { throw SandboxGitRunner.Failure("Ungültiger lokaler Sandbox-Endpunkt.") }
            if let profile, profile != saved.profileName {
                throw SandboxGitRunner.Failure("Am Ziel läuft bereits eine Sandbox mit einem anderen Profil. Bitte zuerst bewusst stoppen oder dieses Profil auswählen.")
            }
            return OpenCodeClient(baseURL: url, password: password)
        }
        guard let cli else {
            guard let shell = localShell(root: root.path, gitAccess: true) else {
                throw SandboxGitRunner.Failure("nono wurde nicht gefunden. Kein Host-Fallback.")
            }
            return shell
        }
        let result = try await cli.startWeb(repoRoot: root.path, project: saved?.projectName, profile: profile ?? saved?.profileName)
        guard result.status == 0 else { throw SandboxGitRunner.Failure("Sandbox-Start fehlgeschlagen: " + result.output) }
        refreshRegistry()
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let entry = try WebSessionRegistry.load().first(where: { sameGitRoot($0.repoRoot, root.path) }),
               WebSessionRegistry.isAlive(entry), let url = entry.baseURL, let password = entry.password {
                guard SandboxGitRunner.isLocalServer(url) else { throw SandboxGitRunner.Failure("Ungültiger lokaler Sandbox-Endpunkt.") }
                let client = OpenCodeClient(baseURL: url, password: password)
                if (try? await client.send("GET", "/api/info", session: GitLabTransport.session)) != nil { return client }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw SandboxGitRunner.Failure("Sandbox-Server ist noch nicht erreichbar. Kein Host-Fallback.")
    }

    private func sameGitRoot(_ left: String, _ right: String) -> Bool {
        URL(fileURLWithPath: left).resolvingSymlinksInPath().standardizedFileURL.path ==
            URL(fileURLWithPath: right).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
