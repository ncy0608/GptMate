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
    var activityKind: TaskActivity = .running
    var startedAt: Date? = nil

    var id: String { threadID }

    static func prioritizingAttention(_ tasks: [ActiveTask]) -> [ActiveTask] {
        tasks.enumerated().sorted {
            if $0.element.activityKind.priority != $1.element.activityKind.priority {
                return $0.element.activityKind.priority < $1.element.activityKind.priority
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}

struct SessionLogState: Equatable {
    let active: Bool
    let activity: String?
    var turnID: String? = nil
    var outcome: TaskOutcome? = nil
    var activityKind: TaskActivity = .running
    var startedAt: Date? = nil
}

enum CodexMessage {
    case rateLimits(RateLimitSnapshot)
    case activeTasks([ActiveTask])
    case quotaReadFailed
    case tasksReadFailed
    case taskEnded(title: String, outcome: TaskOutcome)
}


enum TaskOutcome: String {
    case completed, failed, interrupted, ended

    var notificationTitle: String {
        switch self {
        case .completed: return "Codex 任务完成"
        case .failed: return "Codex 任务失败"
        case .interrupted: return "Codex 任务已中止"
        case .ended: return "Codex 任务已结束"
        }
    }

    static func from(status: String?) -> TaskOutcome {
        switch status {
        case "completed": return .completed
        case "failed": return .failed
        case "interrupted": return .interrupted
        default: return .ended
        }
    }
}

enum StatusTiming {
    static let taskRefreshInterval: TimeInterval = 8
    static let quotaRefreshInterval: TimeInterval = 300

    static func isStale(connected: Bool, updatedAt: Date?, failed: Bool,
                        maxAge: TimeInterval, now: Date) -> Bool {
        guard connected, !failed, let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) >= maxAge
    }

    static func countdown(to reset: Date, now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "已到重置时间，等待额度更新" }
        guard seconds >= 60 else { return "不到 1 分钟后重置" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "还有 \(minutes / 1440) 天 \((minutes % 1440) / 60) 小时重置" }
        if minutes >= 60 { return "还有 \(minutes / 60) 小时 \(minutes % 60) 分钟重置" }
        return "还有 \(minutes) 分钟重置"
    }
}

// Observe a running turn before announcing its end. Disappearance alone is not an end.
struct TaskEndTracker {
    struct Running {
        let title: String
        let path: String?
        let turnID: String?
    }
    private(set) var running: [String: Running] = [:]
    private var lastEndedTurn: [String: String] = [:]

    mutating func observe(id: String, title: String, path: String?, state: SessionLogState?, active: Bool) -> TaskOutcome? {
        if active {
            if let turnID = state?.turnID, lastEndedTurn[id] == turnID { return nil }
            running[id] = Running(title: title, path: path ?? running[id]?.path,
                                  turnID: state?.active == true ? state?.turnID : running[id]?.turnID)
            return nil
        }
        guard let previous = running[id], let state, !state.active,
              let outcome = state.outcome, let turnID = state.turnID,
              previous.turnID == turnID else { return nil }
        running.removeValue(forKey: id)
        lastEndedTurn[id] = turnID
        return outcome
    }

    mutating func finish(id: String, turnID: String) -> String? {
        guard let previous = running[id], previous.turnID == turnID else { return nil }
        running.removeValue(forKey: id)
        lastEndedTurn[id] = turnID
        return previous.title
    }
}
