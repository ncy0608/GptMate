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

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.process?.isRunning == true else {
                self.launch()
                return
            }
            self.requestSnapshot()
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
            self?.queue.async { self?.consume(data) }
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
                        "version": "0.2.0",
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

    private func requestSnapshot() {
        sendRequest(method: "account/rateLimits/read", params: nil)
        sendRequest(
            method: "thread/list",
            params: ["limit": 50, "sortKey": "updated_at"]
        )
    }

    private func sendRequest(method: String, params: Any?) {
        let id = nextRequestID
        nextRequestID += 1
        requests[id] = method

        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        send(message)
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
            let result = message["result"] as? [String: Any]
            switch method {
            case "initialize":
                send(["method": "initialized"])
                onConnectionChange?(true, "已连接 Codex")
                requestSnapshot()
            case "account/rateLimits/read":
                parseRateLimits(result)
            case "thread/list":
                parseThreads(result)
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
            parseRateLimits(params)
        case "turn/plan/updated":
            parsePlan(params)
        case "thread/status/changed", "thread/started", "turn/completed":
            requestSnapshot()
        default:
            break
        }
    }

    private func parseRateLimits(_ container: [String: Any]?) {
        guard let container else { return }
        var snapshot = container["rateLimits"] as? [String: Any]
        if snapshot == nil,
           let buckets = container["rateLimitsByLimitId"] as? [String: Any] {
            snapshot = buckets["codex"] as? [String: Any]
        }
        guard let snapshot else { return }

        let primary = parseWindow(snapshot["primary"])
        let secondary = parseWindow(snapshot["secondary"])
        onMessage?(.rateLimits(primary: primary, secondary: secondary))
    }

    private func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let used = dictionary["usedPercent"] as? NSNumber else {
            return nil
        }
        let duration = (dictionary["windowDurationMins"] as? NSNumber)?.intValue
        let resetTimestamp = (dictionary["resetsAt"] as? NSNumber)?.doubleValue
        return RateLimitWindow(
            usedPercent: used.doubleValue,
            windowDurationMins: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func parseThreads(_ result: [String: Any]?) {
        guard let threads = result?["data"] as? [[String: Any]] else { return }
        var tasks: [ActiveTask] = []

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
            let logState = (thread["path"] as? String).flatMap(SessionLogInspector.inspect)
            let isActive = statusType == "active" || logState?.active == true
            guard isActive else { continue }

            var steps = planSteps[id] ?? []
            if steps.isEmpty, let activity = logState?.activity {
                steps = [PlanStep(step: activity, status: "inProgress")]
            }
            tasks.append(ActiveTask(threadID: id, title: title, steps: steps))
        }

        onMessage?(.activeTasks(tasks))
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
