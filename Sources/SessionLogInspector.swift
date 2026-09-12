import CoreFoundation
import Foundation

enum SessionLogInspector {
    private static let chunkSize: UInt64 = 64 * 1024

    static func inspect(path: String) -> SessionLogState? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        return latestLifecycleState(handle: handle, fileSize: fileSize)
    }

    // Walk backwards to the current turn boundary; older turns cannot supply its status or timer.
    private static func latestLifecycleState(handle: FileHandle, fileSize: UInt64) -> SessionLogState? {
        var end = fileSize
        var suffix = Data()
        var activities: [ActivityEvent] = []
        while end > 0 {
            let start = end > chunkSize ? end - chunkSize : 0
            do {
                try handle.seek(toOffset: start)
                var block = try handle.read(upToCount: Int(end - start)) ?? Data()
                block.append(suffix)
                let lines = block.split(separator: 0x0A, omittingEmptySubsequences: false)
                let complete = start == 0 ? lines[...] : lines.dropFirst()
                for line in complete.reversed() {
                    guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    if let lifecycle = lifecycleRecord(record) {
                        guard lifecycle.active else { return lifecycle }
                        let current = activityState(activities, turnID: lifecycle.turnID)
                        return SessionLogState(active: true, activity: current.text, turnID: lifecycle.turnID,
                                               activityKind: current.kind, startedAt: lifecycle.startedAt)
                    }
                    if let event = ActivityEvent(record) { activities.append(event) }
                }
                suffix = lines.first.map { Data($0) } ?? Data()
                end = start
            } catch { return nil }
        }
        return nil
    }

    static func lifecycleRecord(_ data: Data) -> SessionLogState? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lifecycleRecord(record)
    }

    private static func lifecycleRecord(_ record: [String: Any]) -> SessionLogState? {
        guard record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return nil }
        let turnID = payload["turn_id"] as? String
        switch type {
        case "task_started":
            return SessionLogState(active: true, activity: nil, turnID: turnID,
                                   startedAt: startDate(payload: payload, record: record))
        case "task_complete":
            return SessionLogState(active: false, activity: nil, turnID: turnID,
                                   outcome: TaskOutcome.from(status: payload["status"] as? String))
        case "turn_aborted":
            return SessionLogState(active: false, activity: nil, turnID: turnID, outcome: .interrupted)
        default: return nil
        }
    }

    private static func startDate(payload: [String: Any], record: [String: Any]) -> Date? {
        if let seconds = payload["started_at"] as? NSNumber,
           CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite {
            return Date(timeIntervalSince1970: seconds.doubleValue)
        }
        guard let stamp = record["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }

    private struct ActivityEvent {
        enum Kind { case started, finished, activity }
        let kind: Kind
        let callID: String?
        let turnID: String?
        let activity: TaskActivity
        var text: String? = nil

        init?(_ record: [String: Any]) {
            guard let payload = record["payload"] as? [String: Any], let type = payload["type"] as? String else { return nil }
            turnID = payload["turn_id"] as? String
            switch (record["type"] as? String, type) {
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                guard let id = payload["call_id"] as? String, let name = payload["name"] as? String else { return nil }
                kind = .started; callID = id; activity = TaskActivity.forTool(name)
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                guard let id = payload["call_id"] as? String else { return nil }
                kind = .finished; callID = id; activity = .running
            case ("response_item", "reasoning"):
                kind = .activity; callID = nil; activity = .thinking
            case ("response_item", "message"):
                guard payload["role"] as? String == "assistant" else { return nil }
                kind = .activity; callID = nil; activity = .running
            case ("event_msg", "agent_reasoning"):
                kind = .activity; callID = nil; activity = .thinking
                if let raw = payload["text"] as? String {
                    let cleaned = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    text = cleaned.isEmpty ? nil : String(cleaned.prefix(180))
                }
            case ("event_msg", "item_started"), ("event_msg", "item_completed"):
                guard let item = payload["item"] as? [String: Any],
                      let id = item["id"] as? String, let itemType = item["type"] as? String else { return nil }
                callID = id
                if type == "item_started" {
                    kind = .started; activity = TaskActivity.forItem(itemType)
                } else {
                    kind = .finished; activity = itemType.lowercased() == "reasoning" ? .thinking : .running
                }
            default: return nil
            }
        }
    }

    // Events arrive newest first. A matching output closes a tool even when other tools are still running.
    private static func activityState(_ events: [ActivityEvent], turnID: String?) -> (kind: TaskActivity, text: String?) {
        var finished = Set<String>()
        var pending: TaskActivity?
        var latest: TaskActivity?
        var text: String?
        for event in events where event.turnID == nil || event.turnID == turnID {
            if text == nil { text = event.text }
            switch event.kind {
            case .finished:
                if let id = event.callID { finished.insert(id) }
                if latest == nil { latest = event.activity }
            case .started:
                if let id = event.callID, !finished.contains(id),
                   event.activity.priority < (pending?.priority ?? Int.max) {
                    pending = event.activity
                }
            case .activity:
                if latest == nil { latest = event.activity }
            }
        }
        return (pending ?? latest ?? .running, text)
    }
}

// Owned by the app-server's serial queue; retain only currently observed logs.
final class SessionLogCache {
    private struct Signature: Equatable {
        let size: UInt64
        let modified: Date
        let fileNumber: UInt64

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
            self.size = size.uint64Value
            self.modified = modified
            self.fileNumber = fileNumber.uint64Value
        }
    }

    private var entries: [String: (signature: Signature, state: SessionLogState)] = [:]
    private let parse: (String) -> SessionLogState?

    init(parse: @escaping (String) -> SessionLogState? = SessionLogInspector.inspect) {
        self.parse = parse
    }

    func inspect(path: String) -> SessionLogState? {
        guard let signature = Signature(path: path) else {
            entries.removeValue(forKey: path)
            return nil
        }
        if let cached = entries[path], cached.signature == signature { return cached.state }
        entries.removeValue(forKey: path)
        guard let state = parse(path) else { return nil }
        // A write during parsing must be inspected again on the next refresh.
        if Signature(path: path) == signature { entries[path] = (signature, state) }
        return state
    }

    func retain(paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }
}
