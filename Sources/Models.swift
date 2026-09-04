import Foundation

struct RateLimitWindow: Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        100 - min(max(usedPercent, 0), 100)
    }
}

struct PlanStep: Identifiable, Equatable {
    let id = UUID()
    let step: String
    let status: String

    static func == (lhs: PlanStep, rhs: PlanStep) -> Bool {
        lhs.step == rhs.step && lhs.status == rhs.status
    }
}

struct ActiveTask: Identifiable, Equatable {
    let threadID: String
    let title: String
    let steps: [PlanStep]

    var id: String { threadID }
}

struct SessionLogState: Equatable {
    let active: Bool
    let activity: String?
}

enum CodexMessage {
    case rateLimits(primary: RateLimitWindow?, secondary: RateLimitWindow?)
    case activeTasks([ActiveTask])
}
