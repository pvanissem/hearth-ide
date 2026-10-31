#!/usr/bin/env bash
# CLT-only regression runner: compile actual production sources without Testing macros.
# No keychain access, real tokens or reads/writes of the user's clipboard.
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve
BASE="${TMPDIR:-/tmp/}opencode"
mkdir -p "$BASE"
WORK="$(mktemp -d "$BASE/security-regression.XXXXXX")"
export HEARTH_SECURITY_FIXTURES="$WORK/fixtures"
export HEARTH_UPDATE_INSTALLER="$PWD/install.sh"
mkdir -p "$HEARTH_SECURITY_FIXTURES"
python3 - "$WORK" <<'PY'
from pathlib import Path
import sys, json
repo = Path.cwd()
work = Path(sys.argv[1])
target = work / 'Sources' / 'Regression'
target.mkdir(parents=True)
dependency = str(repo / '.build/checkouts/SwiftTerm')
markdown_dependency = str(repo / '.build/checkouts/swift-markdown')
(work/'Package.swift').write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "SecurityRegression", platforms: [.macOS(.v14)],
 dependencies: [.package(path: SWIFTTERM_PATH), .package(path: MARKDOWN_PATH)],
 targets: [.executableTarget(name: "Regression", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Markdown", package: "swift-markdown")])])
'''.replace('SWIFTTERM_PATH', json.dumps(dependency)).replace('MARKDOWN_PATH', json.dumps(markdown_dependency)))
for source in ['Core/Git.swift', 'Core/InlineDiff.swift', 'Core/JSON.swift', 'Core/GitLabCI.swift', 'Core/OpenCodeClient.swift', 'Core/SandboxGit.swift', 'Core/WebSessionRegistry.swift', 'Core/SandboxHistory.swift', 'Core/ChatFailure.swift', 'Core/ChatMessage.swift', 'Core/ServerConnection.swift', 'Core/PluginCommands.swift', 'Core/FormRequest.swift', 'Core/Notifier.swift', 'Core/ModelCatalog.swift', 'Core/SessionListDisclosure.swift', 'Core/SlashCommands.swift', 'Core/PresentationScope.swift', 'Core/Highlighter.swift', 'Core/SymbolFinder.swift', 'Core/AppUpdates.swift', 'Core/AppUpdateInstaller.swift', 'Core/BuildDeploy.swift', 'Core/BuildRunner.swift', 'UI/TerminalSecurity.swift', 'UI/NativeDirectoryTree.swift', 'UI/ChatFeedback.swift', 'UI/CodeEditor.swift', 'UI/EditorCommands.swift', 'UI/MarkdownView.swift', 'UI/SelectableMarkdown.swift', 'UI/UpdateSettings.swift', 'UI/ComposerTextView.swift']:
    p = repo/'Sources/Hearth'/source
    (target/p.name).write_text(p.read_text())
directory = (repo/'Sources/Hearth/UI/DirectoryActions.swift').read_text()
(target/'WorkspaceFiles.swift').write_text('import Foundation\nimport AppKit\nimport UniformTypeIdentifiers\n'+directory[directory.index('enum WorkspaceFiles'):directory.index('struct DirectoryCreateMenu')]+directory[directory.index('struct WorkspaceFileDrag'):directory.index('struct WorkspaceFileDrop')])
inspector = (repo/'Sources/Hearth/UI/InspectorView.swift').read_text()
(target/'DirectoryModels.swift').write_text('import Foundation\n'+inspector[inspector.index('struct FileNode'):inspector.index('struct DirectoryView')]+inspector[inspector.index('enum FileIcon'):inspector.index('// MARK: Git')])
zoom = (repo/'Sources/Hearth/UI/TextZoom.swift').read_text()
(target/'ScaledFont.swift').write_text(zoom[:zoom.index('extension View {')]+zoom[zoom.index('/// Text-style font'):])
canvas = (repo/'Sources/Hearth/UI/MermaidCanvas.swift').read_text()
# Include the real controller, WebView, security policy and fixed page, not the toolbar UI.
(target/'MermaidRenderer.swift').write_text(canvas[:canvas.index('/// Diagram canvas')] + canvas[canvas.index('/// Renders Mermaid offline'):])
(target/'MermaidAsset.swift').write_text('import Foundation\nenum MermaidAsset {\n static let fileName = "mermaid.min.js"\n static let url: URL? = URL(fileURLWithPath: '+json.dumps(str(repo/'Resources/mermaid.min.js'))+')\n}\n')
tests = (repo/'Tests/HearthTests/SecurityRegressionTests.swift').read_text()
(target/'Tests.swift').write_text(tests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ',''))
networkTests = (repo/'Tests/HearthTests/SandboxGitTests.swift').read_text()
(target/'SandboxGitTests.swift').write_text(networkTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ',''))
directoryTests = (repo/'Tests/HearthTests/DirectoryAndHistoryTests.swift').read_text()
(target/'DirectoryAndHistoryTests.swift').write_text(directoryTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ',''))
chatTests = (repo/'Tests/HearthTests/ChatFeedbackTests.swift').read_text()
(target/'ChatFeedbackTests.swift').write_text(chatTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ',''))
modelTests = (repo/'Tests/HearthTests/ModelsAndSessionListTests.swift').read_text()
(target/'ModelsAndSessionListTests.swift').write_text(modelTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ',''))
contextTests = (repo/'Tests/HearthTests/ContextSwitchTests.swift').read_text()
(target/'ContextSwitchTests.swift').write_text(contextTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ',''))
composerTests = (repo/'Tests/HearthTests/ComposerInputTests.swift').read_text()
(target/'ComposerInputTests.swift').write_text(composerTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ',''))
buildTests = (repo/'Tests/HearthTests/BuildDeployTests.swift').read_text()
(target/'BuildDeployTests.swift').write_text(buildTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ','').replace('@Suite(.serialized)\n',''))
updateTests = (repo/'Tests/HearthTests/AppUpdateTests.swift').read_text()
(target/'AppUpdateTests.swift').write_text(updateTests.replace('import Testing\n','').replace('@testable import Hearth\n','').replace('@Test ','').replace('@Suite(.serialized)\n',''))
(target/'Run.swift').write_text('''import AppKit
@main struct Run {
 @MainActor static func main() {
  NSApplication.shared.setActivationPolicy(.accessory)
  Task { @MainActor in
   do {
    let suite = SecurityRegressionTests()
    try await suite.gitLabOriginBinding(); print("PASS GitLab: origin binding, dummy HTTP request, read/write separation, redirects")
    try suite.terminalClipboardPolicy(); print("PASS Terminal: OSC 52/Kitty denied, no system clipboard access")
    try await suite.gitHelpersCannotExecute(); print("PASS Git: status/diff/show/inline diff, filters, hooks, network policy")
    try suite.directoryMoveValidation(); print("PASS Directory: move, collisions, root/descendant protection, symlink escapes")
    try await suite.mermaidCannotInjectOrConnect(); print("PASS Mermaid: real WebKit render, script injection, CSP, ephemeral storage")
    try await SandboxGitTests().directNetworkOperations(); print("PASS Sandbox Git: fetch/pull/clone HTTP path, output paging, cleanup, no prompt/session, no host fallback")
    try await DirectoryAndHistoryTests().nativeDragDropAndReveal(); print("PASS native directory: AppKit drag writer, drop callbacks, real file/root moves, reveal, provider bridge")
    try DirectoryAndHistoryTests().historyMergesAndSortsBothRegistries(); print("PASS history: web/terminal merge, newest profile/date, running entries, app use, no seven-entry truncation")
    try ChatFeedbackTests().providerFailuresSurviveHistoryParsing(); print("PASS chat errors: cyber_policy, wrapped SSE, empty/partial replies, persisted history, deduplication, full HTTP details")
    try ChatFeedbackTests().activityOnlyWhileAgentWorks(); print("PASS activity: running, permission/form waits, errors, stop, disconnect")
    try await ChatFeedbackTests().liveErrorsSurviveSessionRefresh(); print("PASS live chat state: event ordering, scoped errors, refresh, submit/start/success/stop")
    try await ChatFeedbackTests().feedbackViewsRender(); print("PASS chat feedback views: light/dark, static animation; fixture screenshots written")
    try ModelsAndSessionListTests().modelFactsAndCredentialOrigins(); print("PASS model approvals: explicit policy, picker/local flags, alias IDs, strict HTTPS credential origins")
    try await ModelsAndSessionListTests().catalogRefreshAndFailureAreSafe(); print("PASS model refresh: active account, shared refresh, slash menu, revoke/failure handling, no credential forwarding")
    try ModelsAndSessionListTests().sessionGroupsPersistAndKeepSelection(); print("PASS session groups: independent disclosure, persistence, attention section, selected session preview")
    try ContextSwitchTests().staleLoadsCannotPublishAfterSwitchBack(); print("PASS switch scopes: stale A-B-A loads, disposed views, editor workspace boundaries")
    try ContextSwitchTests().streamsStayWithTheirMessageAndSession(); print("PASS chat stream: scoped message/ordinal overlays, reload during stream, session switch, canonical end, no duplicates")
    try await ContextSwitchTests().nativeEditorSwitchResetsViewNotBuffers(); print("PASS editor lifecycle: identical-content document switch, scroll reset, isolated undo, unsaved buffer retention")
    try await ContextSwitchTests().nativeMarkdownRemeasuresOnTextAndWidthChanges(); print("PASS native Markdown: width changes, growth/shrink remeasurement, reused message view")
    try AppUpdateTests().releaseComparisonDistinguishesDevelopmentBuilds(); print("PASS update versions: numeric comparison, malformed versions, development builds, no downgrade recommendation")
    try await AppUpdateTests().feedAndCheckerAreSafe(); print("PASS update checks: fixed unauthenticated origin, GitHub-only redirects, bounded feed, preferences, manual/shared checks, dismiss/error states")
    try await AppUpdateTests().startupChecksOnceAndSettingsRender(); print("PASS update startup/settings: once per launch, native settings layout")
    try AppUpdateTests().updateHelperRunsInstallerOnlyAfterQuit(); print("PASS update install: waits for app exit, runs installer, reopens old app on failure, aborts if app keeps running")
    try await AppUpdateTests().releaseNotesForUpdateDialog(); print("PASS update notes: changelog parsing, skipped releases, bounded fetch, missing file, dialog rendering")
    try AppUpdateTests().installerRespectsCancelledQuit(); print("PASS installer: cancelled quit blocks replacement (isolated mocked quit guard)")
    try BuildDeployTests().detectsProjectsAndServices(); print("PASS build detection: Maven modules/profiles/Spring Boot, Node/pnpm, Go cmd, Make, custom tasks, unsafe input rejected")
    try BuildDeployTests().commandsAreQuotedAndScoped(); print("PASS build commands: argument quoting, profile validation, port env, cwd confinement, executed Maven proxy settings (0600, removed), network hints")
    try await BuildDeployTests().runnerLifecycleAgainstShellAPI(); print("PASS build runner: output/exit, cleanup, single service, health, stop, port conflict, missing tools, adoption, sandbox loss")
    try await EditorPerformanceTests().tabSwitchKeepsStateAndOverlays(); print("PASS editor tabs: scroll/selection restored in first frame, focus handoff, tab reordering, O(n) line ranges, hunk tint without re-highlight, async colouring of large files")
    if ProcessInfo.processInfo.environment["HEARTH_PERF"] != nil {
        print("PERF editor switch ms:", try await EditorPerformanceTests().measureTabSwitch())
    }
    try await ComposerInputTests().newlineAtCaretSubmitAndScrolling(); print("PASS chat input: ⇧/⌥↩ newline at caret, ↩ submit, popup arrows, scroller, height cap/reset")
    if ProcessInfo.processInfo.environment["HEARTH_LIVE_SANDBOX_ROOT"] != nil {
        try await BuildDeployTests().liveSandboxGoService(); print("PASS live sandbox: go build + service reachable from host and stopped; Maven package with dependencies via sandbox proxy")
    }
    exit(0)
   } catch { FileHandle.standardError.write(Data("FAIL: \\(error)\\n".utf8)); exit(1) }
  }
  NSApplication.shared.run()
 }
}
''')
PY
echo "Security regression workspace: $WORK"
swift run ${HEARTH_PERF:+-c release} --package-path "$WORK" Regression
