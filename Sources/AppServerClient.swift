import Foundation

final class CodexAppServerClient {
    var onMessage: ((CodexMessage) -> Void)?
    var onConnectionChange: ((Bool, String) -> Void)?

    private let queue = DispatchQueue(label: "CodexMeter.AppServer")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var readBuffer = Data()
    private var nextRequestID = 1
    private var requests: [Int: String] = [:]
    private var planSteps: [String: [PlanStep]] = [:]
    private var shouldRestart = true
    private var initialized = false
    private var taskEnds = TaskEndTracker()
    private let logCache = SessionLogCache()

    func start() {
        shouldRestart = true
        queue.async { [weak self] in self?.launch() }
    }

    func stop() {
        shouldRestart = false
        queue.async { [weak self] in self?.stopProcess() }
    }

    func restart() {
        shouldRestart = true
        queue.async { [weak self] in
            self?.stopProcess()
            self?.launch()
        }
    }

    func refresh(includeQuota: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.process?.isRunning == true else {
                self.launch()
                return
            }
            self.requestSnapshot(includeQuota: includeQuota)
        }
    }

    deinit {
        shouldRestart = false
        stopProcess()
    }

    private func launch() {
        guard process?.isRunning != true else { return }
        guard let executable = findCodexExecutable() else {
            onConnectionChange?(false, "找不到 Codex CLI")
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                guard let self, self.process === process else { return }
                self.consume(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                guard let self, self.process === process else { return }
                let code = process.terminationStatus
                self.clearProcessReferences()
                self.onConnectionChange?(false, "Codex 连接已断开（\(code)）")
                guard self.shouldRestart else { return }
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.launch()
                }
            }
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            output = stdoutPipe.fileHandleForReading
            errorOutput = stderrPipe.fileHandleForReading
            readBuffer.removeAll(keepingCapacity: true)
            requests.removeAll(keepingCapacity: true)
            nextRequestID = 1

            sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex-meter",
                        "title": "GptMate",
                        "version": "0.3.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ]
            )
        } catch {
            clearProcessReferences()
            onConnectionChange?(false, "无法启动 Codex：\(error.localizedDescription)")
        }
    }

    private func stopProcess() {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        clearProcessReferences()
    }

    private func clearProcessReferences() {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        initialized = false
        process = nil
        input = nil
        output = nil
        errorOutput = nil
    }

    private func findCodexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.cargo/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refreshQuota() {
        queue.async { [weak self] in self?.requestQuota() }
    }

    private func requestQuota() {
        guard initialized else { return }
        sendRequest(method: "account/rateLimits/read", params: nil)
    }

    private func requestSnapshot(includeQuota: Bool = true) {
        guard initialized else { return }
        if includeQuota { requestQuota() }
        sendRequest(
            method: "thread/list",
            params: ["limit": 50, "sortKey": "updated_at"]
        )
    }

    private func sendRequest(method: String, params: Any?) {
        guard !requests.values.contains(method) else { return }
        let id = nextRequestID
        nextRequestID += 1
        requests[id] = method

        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        send(message)
        queue.asyncAfter(deadline: .now() + 20) { [weak self, weak source = process] in
            guard let self, let source, self.process === source, self.requests[id] != nil else { return }
            self.requests.removeValue(forKey: id)
            if method == "initialize" {
                self.onConnectionChange?(false, "连接超时，正在重新连接…")
                self.stopProcess()
                if self.shouldRestart { self.launch() }
            } else {
                self.reportReadFailure(method)
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }
        var line = data
        line.append(0x0A)
        do {
            try input?.write(contentsOf: line)
        } catch {
            onConnectionChange?(false, "发送请求失败：\(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[..<newline]
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any] else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = (message["id"] as? NSNumber)?.intValue,
           let method = requests.removeValue(forKey: id) {
            guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                reportReadFailure(method)
                return
            }
            switch method {
            case "initialize":
                initialized = true
                send(["method": "initialized"])
                onConnectionChange?(true, "已连接 Codex")
                requestSnapshot()
            case "account/rateLimits/read":
                if !parseRateLimits(result) { reportReadFailure(method) }
            case "thread/list":
                if !parseThreads(result) { reportReadFailure(method) }
            default:
                break
            }
            return
        }

        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else {
            return
        }
        switch method {
        case "account/rateLimits/updated":
            requestQuota()
        case "account/updated":
            requestSnapshot()
        case "turn/plan/updated":
            parsePlan(params)
        case "turn/completed":
            if let threadID = params["threadId"] as? String,
               let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String,
               let status = turn["status"] as? String, status != "inProgress" {
                let outcome = TaskOutcome.from(status: status)
                if let title = taskEnds.finish(id: threadID, turnID: turnID) {
                    onMessage?(.taskEnded(title: title, outcome: outcome))
                }
            }
            requestSnapshot(includeQuota: false)
        case "thread/status/changed", "thread/started":
            requestSnapshot(includeQuota: false)
        default:
            break
        }
    }

    private func reportReadFailure(_ method: String) {
        switch method {
        case "account/rateLimits/read": onMessage?(.quotaReadFailed)
        case "thread/list": onMessage?(.tasksReadFailed)
        default: onConnectionChange?(false, "连接失败，请检查 Codex 登录状态或重连")
        }
    }

    private func parseRateLimits(_ container: [String: Any]?) -> Bool {
        guard let container, let snapshot = RateLimitSnapshot.parse(container) else { return false }
        onMessage?(.rateLimits(snapshot))
        return true
    }

    private func parseThreads(_ result: [String: Any]?) -> Bool {
        guard let threads = result?["data"] as? [[String: Any]] else { return false }
        var tasks: [ActiveTask] = []

        var inspected = Set<String>()
        for thread in threads.prefix(20) {
            guard let id = thread["id"] as? String else { continue }
            let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (thread["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = [name, preview].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.first ?? "未命名任务"

            let status = thread["status"] as? [String: Any]
            let statusType = status?["type"] as? String
            let path = thread["path"] as? String
            let logState = path.flatMap { logCache.inspect(path: $0) }
            inspected.insert(id)
            let isActive = logState?.active ?? (statusType == "active")
            if let outcome = taskEnds.observe(id: id, title: title, path: path, state: logState, active: isActive) {
                onMessage?(.taskEnded(title: title, outcome: outcome))
            }
            guard isActive else { continue }

            var steps = planSteps[id] ?? []
            if steps.isEmpty, let activity = logState?.activity {
                steps = [PlanStep(step: activity, status: "inProgress")]
            }
            let activity = TaskActivity.resolve(status: status, logActivity: logState?.activityKind ?? .running)
            tasks.append(ActiveTask(threadID: id, title: title, steps: steps,
                                    activityKind: activity, startedAt: logState?.startedAt))
        }

        // A task outside the recent list is only ended after checking its known log.
        for (id, running) in taskEnds.running where !inspected.contains(id) {
            guard let path = running.path, let state = logCache.inspect(path: path) else { continue }
            if let outcome = taskEnds.observe(id: id, title: running.title, path: path, state: state, active: state.active) {
                onMessage?(.taskEnded(title: running.title, outcome: outcome))
            } else if state.active {
                tasks.append(ActiveTask(threadID: id, title: running.title, steps: [],
                                        activityKind: state.activityKind, startedAt: state.startedAt))
            }
        }
        let recentPaths = threads.prefix(20).compactMap { $0["path"] as? String }
        logCache.retain(paths: Set(recentPaths + taskEnds.running.values.compactMap(\.path)))
        onMessage?(.activeTasks(ActiveTask.prioritizingAttention(tasks)))
        return true
    }

    private func parsePlan(_ params: [String: Any]) {
        guard let threadID = params["threadId"] as? String,
              let plan = params["plan"] as? [[String: Any]] else {
            return
        }
        planSteps[threadID] = plan.compactMap { item in
            guard let step = item["step"] as? String,
                  let status = item["status"] as? String else {
                return nil
            }
            return PlanStep(step: step, status: status)
        }
    }
}
