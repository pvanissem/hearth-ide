import Foundation
import Testing
@testable import Hearth

struct WebSessionRegistryTests {
    @Test func decodesRegistry() throws {
        let json = """
        {"version":1,"entries":[{"id":"a","repoRoot":"/tmp/repo","profileName":"p","port":"1234",
        "pid":42,"status":"running","password":"pw","createdAt":"2026-01-01T00:00:00Z","unknown":true}]}
        """
        let entries = try WebSessionRegistry.decode(Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].baseURL?.absoluteString == "http://127.0.0.1:1234")
        #expect(entries[0].displayName == "repo")
        #expect(entries[0].isRunning)
    }

    @Test func rejectsUnknownVersion() {
        #expect(throws: (any Error).self) {
            try WebSessionRegistry.decode(Data(#"{"version":2,"entries":[]}"#.utf8))
        }
    }

    @Test func parsesAssistantMessage() {
        let json = JSON.parse(Data(#"{"id":"m","type":"assistant","content":[{"type":"text","text":"pong"}]}"#.utf8))!
        #expect(ChatMessage(json: json)?.text == "pong")
        #expect(ChatMessage(json: JSON.parse(Data(#"{"id":"x","type":"idle"}"#.utf8))!) == nil)
    }
}
