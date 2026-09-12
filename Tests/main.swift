import Foundation

func check(_ condition: @autoclosure () -> Bool, _ title: String) {
    precondition(condition(), title)
    print("PASS: \(title)")
}
let now = Date(timeIntervalSince1970: 100000)
check(!StatusTiming.isStale(connected: true, updatedAt: now, failed: false, maxAge: StatusTiming.quotaRefreshInterval + 30, now: now), "fresh snapshot")
check(StatusTiming.isStale(connected: false, updatedAt: now, failed: false, maxAge: StatusTiming.quotaRefreshInterval + 30, now: now), "disconnect immediately stale")
check(StatusTiming.isStale(connected: true, updatedAt: now.addingTimeInterval(-30), failed: false, maxAge: 30, now: now), "task timeout despite fresh quota")
check(StatusTiming.isStale(connected: true, updatedAt: nil, failed: false, maxAge: StatusTiming.quotaRefreshInterval + 30, now: now), "unknown quota never fresh")
check(StatusTiming.countdown(to: now.addingTimeInterval(90000), now: now) == "还有 1 天 1 小时重置", "day countdown")
check(StatusTiming.countdown(to: now.addingTimeInterval(3660), now: now) == "还有 1 小时 1 分钟重置", "hour countdown")
check(StatusTiming.countdown(to: now, now: now).contains("等待额度更新"), "elapsed reset does not fabricate new allowance")
func event(_ type: String, turn: String = "t1") -> Data {
    try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": type, "turn_id": turn]])
}
let started = SessionLogInspector.lifecycleRecord(event("task_started"))!
let ended = SessionLogInspector.lifecycleRecord(event("task_complete"))!
let aborted = SessionLogInspector.lifecycleRecord(event("turn_aborted"))!
check(ended.outcome == .ended, "unknown outcome is not success")
check(aborted.outcome == .interrupted, "explicit abort recognized")
check(SessionLogInspector.lifecycleRecord(Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"task_complete\"}}".utf8)) == nil, "ignore non-event lookalikes")
var tracker = TaskEndTracker()
check(tracker.observe(id: "a", title: "test", path: nil, state: ended, active: false) == nil, "no historical notification at startup")
_ = tracker.observe(id: "a", title: "test", path: nil, state: started, active: true)
check(tracker.observe(id: "a", title: "test", path: nil, state: nil, active: false) == nil, "disappearance is not completion")
check(tracker.observe(id: "a", title: "test", path: nil, state: SessionLogInspector.lifecycleRecord(event("task_complete", turn: "other")), active: false) == nil, "different turn cannot finish active turn")
_ = tracker.observe(id: "a", title: "test", path: nil, state: nil, active: true)
check(tracker.running["a"]?.turnID == "t1", "temporary log read failure preserves observed turn")
check(tracker.observe(id: "a", title: "test", path: nil, state: aborted, active: false) == .interrupted, "matched abort notifies")
check(tracker.observe(id: "a", title: "test", path: nil, state: aborted, active: false) == nil, "no duplicate notification")
let nextStart = SessionLogInspector.lifecycleRecord(event("task_started", turn: "t2"))!
_ = tracker.observe(id: "a", title: "test", path: nil, state: nextStart, active: true)
check(tracker.finish(id: "a", turnID: "t2") == "test", "explicit failed turn")
check(tracker.finish(id: "a", turnID: "t2") == nil, "notification and polling deduplicate")
let path = NSTemporaryDirectory() + UUID().uuidString + ".jsonl"
var data = event("task_started")
data.append(10)
data.append(Data(repeating: 32, count: 65520))
data.append(10)
data.append(event("turn_aborted"))
data.append(10)
try data.write(to: URL(fileURLWithPath: path))
check(SessionLogInspector.inspect(path: path)?.outcome == .interrupted, "chunk boundary log reading")
try FileManager.default.removeItem(atPath: path)

_ = tracker.observe(id: "a", title: "test", path: nil, state: nextStart, active: true)
check(tracker.observe(id: "a", title: "test", path: nil, state: SessionLogInspector.lifecycleRecord(event("task_complete", turn: "t2")), active: false) == nil, "late log cannot duplicate server notification")
check(TaskOutcome.from(status: "completed") == .completed && TaskOutcome.from(status: "failed") == .failed, "explicit terminal outcomes preserved")
var longLog = event("task_started")
longLog.append(10)
longLog.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": String(repeating: "x", count: 140000)]))
longLog.append(10)
try longLog.write(to: URL(fileURLWithPath: path))
check(SessionLogInspector.inspect(path: path)?.active == true, "find lifecycle preceding multi-chunk record")
try FileManager.default.removeItem(atPath: path)

func quotaWindow(_ used: Any, minutes: Any = 10080, reset: Any = 200000) -> [String: Any] {
    ["usedPercent": used, "windowDurationMins": minutes, "resetsAt": reset]
}
let general: [String: Any] = ["limitId": "codex", "limitName": NSNull(), "primary": quotaWindow(20), "secondary": NSNull()]
let spark: [String: Any] = ["limitName": "GPT-5.3-Codex-Spark", "primary": quotaWindow(95, minutes: 300), "secondary": quotaWindow(10)]
let legacyOnly = RateLimitSnapshot.parse(["rateLimits": general])!
check(legacyOnly.buckets.count == 1 && legacyOnly.buckets[0].name == "Codex", "legacy response remains supported")
check(legacyOnly.menuBarWindow?.remainingPercent == 80, "legacy menu ring value preserved")
let multiple = RateLimitSnapshot.parse([
    "rateLimits": ["limitId": "codex", "primary": quotaWindow(99)],
    "rateLimitsByLimitId": ["codex_bengalfox": spark, "codex": general],
])!
check(multiple.buckets.map(\.id) == ["codex", "codex_bengalfox"], "all buckets parsed with general allowance first")
check(multiple.buckets[1].name == "GPT-5.3-Codex-Spark", "server model name preserved")
check(multiple.buckets[1].primary?.windowDurationMins == 300 && multiple.buckets[1].secondary?.windowDurationMins == 10080, "both model-specific windows preserved")
check(multiple.menuBarWindow?.remainingPercent == 80, "multi-bucket snapshot wins over legacy mirror without changing ring to constrained model")
check(multiple.buckets.count == 2, "legacy mirror is not duplicated")
let future = RateLimitSnapshot.parse(["rateLimitsByLimitId": [
    "future-monthly": ["limitName": "未来模型", "primary": quotaWindow(25, minutes: 43200)],
    "future-short": ["limitName": " ", "primary": quotaWindow(5, minutes: 90)],
    "invalid": "bad value",
]])!
check(future.buckets.map(\.id) == ["future-monthly", "future-short"], "unknown bucket IDs retained in stable order; malformed entry isolated")
check(future.buckets[1].name == "future-short", "missing display name uses stable bucket ID")
check(future.buckets[0].primary?.windowDurationMins == 43200 && future.buckets[1].primary?.windowDurationMins == 90, "periods are not hardcoded to five hours or seven days")
check(RateLimitSnapshot.parse([:]) == nil, "malformed response does not become a fresh empty snapshot")
check(RateLimitSnapshot.parse(["rateLimits": general, "rateLimitsByLimitId": NSNull()]) == legacyOnly, "nullable multi-bucket field falls back to legacy")
check(RateLimitSnapshot.parse(["rateLimits": general, "rateLimitsByLimitId": [:]]) == legacyOnly, "empty multi-bucket field falls back to legacy")
check(RateLimitSnapshot.parse(["rateLimitsByLimitId": [:]])?.buckets.isEmpty == true, "valid empty result can clear previously displayed models")
let unavailable = RateLimitSnapshot.parse(["rateLimitsByLimitId": ["future": ["primary": NSNull(), "secondary": NSNull()]]])!
check(unavailable.buckets.count == 1 && unavailable.menuBarWindow == nil, "missing usage remains unknown rather than zero")
let partial = RateLimitSnapshot.parse(["rateLimitsByLimitId": ["codex": ["primary": quotaWindow(true), "secondary": quotaWindow(100, minutes: NSNull(), reset: NSNull())]]])!
check(partial.buckets[0].primary == nil && partial.menuBarWindow?.remainingPercent == 0, "boolean usage rejected; secondary-only quota supported")
check(partial.menuBarWindow?.windowDurationMins == nil && partial.menuBarWindow?.resetsAt == nil, "missing period and reset are not invented")
check(RateLimitSnapshot.parse(["rateLimits": ["primary": quotaWindow(Double.infinity)]])?.menuBarWindow == nil, "non-finite usage rejected")
check(RateLimitSnapshot.parse(["rateLimits": ["primary": quotaWindow(105)]])?.menuBarWindow?.remainingPercent == 0, "over-limit usage clamps to zero remaining")

func activityRecord(_ outer: String, _ payload: [String: Any], stamp: String = "2026-09-12T04:00:00.123Z") -> Data {
    try! JSONSerialization.data(withJSONObject: ["type": outer, "payload": payload, "timestamp": stamp])
}
func inspectActivity(_ records: [Data]) -> SessionLogState? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    var data = Data()
    for record in records { data.append(record); data.append(10) }
    try! data.write(to: url)
    return SessionLogInspector.inspect(path: url.path)
}
let turnStart = activityRecord("event_msg", ["type": "task_started", "turn_id": "activity-1", "started_at": 100000])
let reasoning = activityRecord("response_item", ["type": "reasoning"])
let command = activityRecord("response_item", ["type": "function_call", "call_id": "cmd-1", "name": "functions.exec_command"])
let commandOutput = activityRecord("response_item", ["type": "function_call_output", "call_id": "cmd-1", "output": "done"])
let inputRequest = activityRecord("response_item", ["type": "function_call", "call_id": "input-1", "name": "request_user_input"])
let inputOutput = activityRecord("response_item", ["type": "function_call_output", "call_id": "input-1", "output": "answer"])
check(inspectActivity([turnStart])?.startedAt == now, "timer uses actual turn start, not app launch")
let timestampStart = activityRecord("event_msg", ["type": "task_started", "turn_id": "activity-1"])
check(abs(inspectActivity([timestampStart])!.startedAt!.timeIntervalSince1970 - 1789185600.123) < 0.001, "ISO timestamp fallback supports fractional seconds")
check(inspectActivity([event("task_started")])?.startedAt == nil, "missing start time remains unknown")
check(TaskActivity.elapsed(since: now, now: now.addingTimeInterval(65)) == "1 分 5 秒", "elapsed minutes and seconds")
check(TaskActivity.elapsed(since: now, now: now.addingTimeInterval(3665)) == "1 小时 1 分 5 秒", "elapsed hours")
check(TaskActivity.elapsed(since: nil, now: now) == nil, "unknown duration is not zero")
check(TaskActivity.elapsed(since: now, now: now.addingTimeInterval(-2)) == "0 秒", "clock reversal cannot produce negative duration")
check(inspectActivity([turnStart, reasoning])?.activityKind == .thinking, "explicit reasoning state")
check(inspectActivity([turnStart, reasoning, command])?.activityKind == .executingCommand, "unfinished command takes precedence over previous reasoning")
check(inspectActivity([turnStart, command, commandOutput])?.activityKind == .running, "finished command is no longer executing")
check(inspectActivity([turnStart, command, commandOutput, reasoning])?.activityKind == .thinking, "reasoning can resume after tool output")
check(inspectActivity([turnStart, inputRequest])?.activityKind == .waitingForInput, "explicit blocking input request")
check(inspectActivity([turnStart, inputRequest, inputOutput])?.activityKind == .running, "input response clears waiting state")
check(inspectActivity([turnStart, inputRequest, command, commandOutput])?.activityKind == .waitingForInput, "one completed tool does not hide another pending request")
let patch = activityRecord("response_item", ["type": "custom_tool_call", "call_id": "patch-1", "name": "apply_patch"])
let patchOutput = activityRecord("response_item", ["type": "custom_tool_call_output", "call_id": "patch-1"])
check(inspectActivity([turnStart, patch])?.activityKind == .editingFiles, "custom patch tool state")
check(inspectActivity([turnStart, patch, patchOutput])?.activityKind == .running, "custom tool completion matched by call ID")
check(TaskActivity.forTool("request_user_input_async") == .usingTool, "asynchronous question does not imply the agent is blocked")
check(TaskActivity.forTool("exec") == .usingTool && TaskActivity.forTool("unknown_tool") == .usingTool, "generic tool names do not fabricate a specific operation")
let compaction = activityRecord("event_msg", ["type": "item_started", "turn_id": "activity-1", "item": ["type": "ContextCompaction", "id": "compact-1"]])
let compactionEnd = activityRecord("event_msg", ["type": "item_completed", "turn_id": "activity-1", "item": ["type": "ContextCompaction", "id": "compact-1"]])
check(inspectActivity([turnStart, compaction])?.activityKind == .compacting, "explicit compaction start")
check(inspectActivity([turnStart, compaction, compactionEnd])?.activityKind == .running, "compaction completion clears activity")
let unrelated = activityRecord("event_msg", ["type": "item_started", "turn_id": "other", "item": ["type": "ContextCompaction", "id": "other-compact"]])
check(inspectActivity([turnStart, unrelated])?.activityKind == .running, "unrelated turn events are ignored")
let nextTurn = activityRecord("event_msg", ["type": "task_started", "turn_id": "activity-2", "started_at": 100060])
let nextState = inspectActivity([turnStart, inputRequest, nextTurn])!
check(nextState.activityKind == .running && nextState.startedAt == now.addingTimeInterval(60), "new turn resets previous waiting state and timer")
check(inspectActivity([turnStart, command, event("task_complete", turn: "activity-1")])?.active == false, "turn completion wins over unfinished historical tool records")
let oldText = activityRecord("event_msg", ["type": "agent_reasoning", "text": "old activity"])
check(inspectActivity([turnStart, oldText, nextTurn])?.activity == nil, "activity summary cannot leak from the previous turn")
check(TaskActivity.resolve(status: ["type": "active", "activeFlags": ["waitingOnApproval"]], logActivity: .executingCommand) == .waitingForApproval, "runtime approval flag overrides generic tool activity")
check(TaskActivity.resolve(status: ["type": "active", "activeFlags": ["waitingOnUserInput"]], logActivity: .thinking) == .waitingForInput, "runtime input flag recognized")
check(TaskActivity.resolve(status: ["type": "active", "activeFlags": [String]()], logActivity: .waitingForInput) == .running, "fresh runtime flags clear old waiting state")
check(TaskActivity.resolve(status: ["type": "notLoaded"], logActivity: .executingCommand) == .executingCommand, "unavailable runtime state uses actual log events")
let tasksToSort = [
    ActiveTask(threadID: "run1", title: "run1", steps: [], activityKind: .thinking),
    ActiveTask(threadID: "input", title: "input", steps: [], activityKind: .waitingForInput),
    ActiveTask(threadID: "approve", title: "approve", steps: [], activityKind: .waitingForApproval),
    ActiveTask(threadID: "run2", title: "run2", steps: [], activityKind: .executingCommand),
]
check(ActiveTask.prioritizingAttention(tasksToSort).map(\.id) == ["approve", "input", "run1", "run2"], "attention tasks first; other task order stays stable")

check(!StatusTiming.isStale(connected: true, updatedAt: now.addingTimeInterval(-300), failed: false, maxAge: StatusTiming.quotaRefreshInterval + 30, now: now), "five-minute quota cadence does not falsely mark data stale")
check(StatusTiming.isStale(connected: true, updatedAt: now.addingTimeInterval(-330), failed: false, maxAge: StatusTiming.quotaRefreshInterval + 30, now: now), "quota overdue beyond cadence and grace becomes stale")
var parseCount = 0
let logCache = SessionLogCache { path in
    parseCount += 1
    return SessionLogInspector.inspect(path: path)
}
var cachedLog = event("task_started")
cachedLog.append(10)
try cachedLog.write(to: URL(fileURLWithPath: path))
check(logCache.inspect(path: path)?.active == true, "cache parses first observation")
for _ in 0..<20 { _ = logCache.inspect(path: path) }
check(parseCount == 1, "unchanged log avoids twenty repeated parses")
cachedLog.append(event("task_complete"))
cachedLog.append(10)
try cachedLog.write(to: URL(fileURLWithPath: path))
check(logCache.inspect(path: path)?.active == false && parseCount == 2, "appended completion invalidates cache")
let priorMtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
var rewritten = event("task_started")
rewritten.append(10)
rewritten.append(Data(repeating: 32, count: cachedLog.count - rewritten.count))
try rewritten.write(to: URL(fileURLWithPath: path))
try FileManager.default.setAttributes([.modificationDate: priorMtime.addingTimeInterval(1)], ofItemAtPath: path)
check(logCache.inspect(path: path)?.active == true && parseCount == 3, "same-size rewrite invalidates cache by modification time")
try cachedLog.write(to: URL(fileURLWithPath: path), options: .atomic)
try FileManager.default.setAttributes([.modificationDate: priorMtime.addingTimeInterval(1)], ofItemAtPath: path)
check(logCache.inspect(path: path)?.active == false && parseCount == 4, "same-size same-time file replacement invalidates cache by identity")
logCache.retain(paths: [])
_ = logCache.inspect(path: path)
check(parseCount == 5, "unobserved logs are evicted")
try FileManager.default.removeItem(atPath: path)
check(logCache.inspect(path: path) == nil, "deleted log does not reuse cached activity")
try Data("incomplete".utf8).write(to: URL(fileURLWithPath: path))
_ = logCache.inspect(path: path)
_ = logCache.inspect(path: path)
check(parseCount == 7, "failed parses are retried rather than cached")
try FileManager.default.removeItem(atPath: path)

check(StatusTiming.isStale(connected: true, updatedAt: now, failed: true, maxAge: 330, now: now), "read failure immediately invalidates recently refreshed data")
check(!StatusTiming.isStale(connected: true, updatedAt: now.addingTimeInterval(-29), failed: false, maxAge: 30, now: now), "task snapshot fresh before timeout")
check(StatusTiming.isStale(connected: false, updatedAt: now, failed: false, maxAge: 30, now: now), "disconnected tasks are stale")
