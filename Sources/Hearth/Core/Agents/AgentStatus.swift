import Foundation

/// Status of an agent session as shown in the inbox.
enum AgentStatus: String, Sendable {
    case running = "RUNNING"
    case needsInput = "NEEDS INPUT"
    case blocked = "BLOCKED"
    case done = "DONE"
    case idle = "IDLE"
    case inactive = "INACTIVE"

    /// Lower sorts first in the inbox: things needing attention on top.
    var priority: Int {
        switch self {
        case .needsInput: 0
        case .blocked: 1
        case .running: 2
        case .done: 3
        case .idle: 4
        case .inactive: 5
        }
    }
}
