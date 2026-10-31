import Foundation

/// Test results and coverage read from report files the build already writes
/// (JUnit XML from Surefire/Failsafe/Gradle/Jest/pytest…, JaCoCo, Cobertura,
/// lcov, Go coverprofile). The app never runs tests itself; that stays in the sandbox.
struct TestCase: Identifiable, Hashable, Sendable {
    enum Outcome: String, Sendable { case passed, failed, error, skipped }
    let id: String
    let suite: String
    let className: String
    let name: String
    let time: Double
    let outcome: Outcome
    let message: String?
    let details: String?
}

struct TestSuite: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let file: String
    var cases: [TestCase]
    var failed: Int { cases.filter { $0.outcome == .failed || $0.outcome == .error }.count }
}

struct Coverage: Hashable, Sendable {
    let source: String
    let covered: Int
    let total: Int
    var percent: Double { total == 0 ? 0 : Double(covered) / Double(total) * 100 }
}

struct TestReport: Sendable {
    var suites: [TestSuite] = []
    var coverage: [Coverage] = []
    var newest: Date?

    var cases: [TestCase] { suites.flatMap(\.cases) }
    var passed: Int { cases.filter { $0.outcome == .passed }.count }
    var failed: Int { cases.filter { $0.outcome == .failed || $0.outcome == .error }.count }
    var skipped: Int { cases.filter { $0.outcome == .skipped }.count }
    var isEmpty: Bool { suites.isEmpty && coverage.isEmpty }
}

enum TestReports {
    static let skipped: Set<String> = [".git", "node_modules", ".build", ".gradle", ".venv", "vendor", ".idea", ".swiftpm"]
    static let maxFiles = 2000

    static func load(root: String) async -> TestReport {
        await Task.detached(priority: .utility) { scan(root: root) }.value
    }

    static func scan(root: String) -> TestReport {
        var report = TestReport()
        let rootURL = URL(fileURLWithPath: root)
        guard let it = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: []) else {
            return report
        }
        var seen = 0
        while let url = it.nextObject() as? URL, seen < maxFiles {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if skipped.contains(name) { it.skipDescendants() }
                continue
            }
            let rel = String(url.path.dropFirst(rootURL.path.count + 1))
            let lower = name.lowercased()
            var matched = false
            if lower.hasSuffix(".xml") {
                if lower == "jacoco.xml" || (lower.hasPrefix("jacoco") && rel.contains("jacoco")) {
                    if let c = jacoco(url, label: rel) { report.coverage.append(c); matched = true }
                } else if lower == "coverage.xml" || lower == "cobertura.xml" || lower.hasSuffix("cobertura-coverage.xml") {
                    if let c = cobertura(url, label: rel) { report.coverage.append(c); matched = true }
                } else if looksLikeJUnit(name: lower, rel: rel) {
                    let suites = junit(url, file: rel)
                    report.suites += suites
                    matched = !suites.isEmpty
                }
            } else if lower == "lcov.info" {
                if let c = lcov(url, label: rel) { report.coverage.append(c); matched = true }
            } else if lower == "coverage.out" || lower.hasSuffix(".coverprofile") || lower == "cover.out" {
                if let c = goCover(url, label: rel) { report.coverage.append(c); matched = true }
            }
            if matched {
                seen += 1
                if let d = values?.contentModificationDate, d > (report.newest ?? .distantPast) { report.newest = d }
            }
        }
        report.suites.sort { ($0.failed > 0 ? 0 : 1, $0.name) < ($1.failed > 0 ? 0 : 1, $1.name) }
        return report
    }

    static func looksLikeJUnit(name: String, rel: String) -> Bool {
        if name.hasPrefix("test-") || name.hasPrefix("junit") { return true }
        let dirs = ["surefire-reports", "failsafe-reports", "test-results", "test-reports", "junit"]
        return dirs.contains { rel.contains($0) }
    }

    // MARK: JUnit XML

    static func junit(_ url: URL, file: String) -> [TestSuite] {
        guard let parser = XMLParser(contentsOf: url) else { return [] }
        let d = JUnitDelegate(file: file)
        parser.delegate = d
        parser.parse()
        return d.suites.filter { !$0.cases.isEmpty }
    }

    final class JUnitDelegate: NSObject, XMLParserDelegate {
        let file: String
        var suites: [TestSuite] = []
        private var suiteStack: [TestSuite] = []
        private var current: [String: String]?
        private var outcome: TestCase.Outcome = .passed
        private var message: String?
        private var text = ""
        private var counter = 0

        init(file: String) { self.file = file }

        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            switch el {
            case "testsuite":
                counter += 1
                let name = a["name"] ?? (file as NSString).lastPathComponent
                suiteStack.append(TestSuite(id: "\(file)#\(counter)", name: name, file: file, cases: []))
            case "testcase":
                current = a
                outcome = .passed
                message = nil
                text = ""
            case "failure", "error":
                outcome = el == "failure" ? .failed : .error
                message = a["message"] ?? a["type"]
                text = ""
            case "skipped", "ignored", "disabled":
                outcome = .skipped
                message = a["message"]
            default:
                break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, foundCDATA d: Data) { text += String(decoding: d, as: UTF8.self) }

        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            switch el {
            case "testcase":
                guard let a = current else { return }
                if suiteStack.isEmpty {
                    suiteStack.append(TestSuite(id: "\(file)#0", name: (file as NSString).lastPathComponent, file: file, cases: []))
                }
                let suite = suiteStack[suiteStack.count - 1]
                let details = outcome == .failed || outcome == .error ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                suiteStack[suiteStack.count - 1].cases.append(TestCase(
                    id: "\(suite.id)#\(suite.cases.count)", suite: suite.name,
                    className: a["classname"] ?? suite.name, name: a["name"] ?? "?",
                    time: Double(a["time"] ?? "") ?? 0, outcome: outcome,
                    message: message, details: details?.isEmpty == true ? nil : details))
                current = nil
            case "testsuite":
                if let s = suiteStack.popLast() { suites.append(s) }
            default:
                break
            }
        }
    }

    // MARK: Coverage formats

    /// JaCoCo: report-level <counter type="LINE" missed=".." covered=".."/>.
    static func jacoco(_ url: URL, label: String) -> Coverage? {
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // The report-level counters are the last LINE counter in the file.
        guard let regex = try? NSRegularExpression(pattern: #"<counter type="LINE" missed="(\d+)" covered="(\d+)"/>"#),
              let match = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).last,
              let missedRange = Range(match.range(at: 1), in: xml), let coveredRange = Range(match.range(at: 2), in: xml),
              let missed = Int(xml[missedRange]), let covered = Int(xml[coveredRange]) else { return nil }
        return Coverage(source: label, covered: covered, total: missed + covered)
    }

    /// Cobertura: root <coverage lines-covered=".." lines-valid="..">.
    static func cobertura(_ url: URL, label: String) -> Coverage? {
        guard let xml = try? String(contentsOf: url, encoding: .utf8),
              let start = xml.range(of: "<coverage "),
              let end = xml[start.upperBound...].range(of: ">") else { return nil }
        let tag = String(xml[start.lowerBound..<end.lowerBound])
        func attr(_ n: String) -> Int? {
            guard let r = tag.range(of: #"\#(n)="(\d+)""#, options: .regularExpression) else { return nil }
            return Int(tag[r].split(separator: "\"")[1])
        }
        guard let covered = attr("lines-covered"), let valid = attr("lines-valid") else { return nil }
        return Coverage(source: label, covered: covered, total: valid)
    }

    static func lcov(_ url: URL, label: String) -> Coverage? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var found = 0, hit = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("LF:") { found += Int(line.dropFirst(3)) ?? 0 }
            if line.hasPrefix("LH:") { hit += Int(line.dropFirst(3)) ?? 0 }
        }
        return found > 0 ? Coverage(source: label, covered: hit, total: found) : nil
    }

    /// Go coverprofile: "file:start,end numStmts count" per block (statement coverage).
    static func goCover(_ url: URL, label: String) -> Coverage? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("mode:") else { return nil }
        var blocks: [Substring: (Int, Bool)] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ")
            guard f.count == 3, let n = Int(f[1]), let c = Int(f[2]) else { continue }
            let prev = blocks[f[0]]
            blocks[f[0]] = (n, (prev?.1 ?? false) || c > 0)
        }
        let total = blocks.values.reduce(0) { $0 + $1.0 }
        let covered = blocks.values.reduce(0) { $0 + ($1.1 ? $1.0 : 0) }
        return total > 0 ? Coverage(source: label, covered: covered, total: total) : nil
    }
}
