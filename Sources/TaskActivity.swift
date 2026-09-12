import Foundation

enum TaskActivity: Equatable {
    case running, thinking, executingCommand, editingFiles, readingFiles, searching, usingTool, compacting
    case waitingForApproval, waitingForInput

    var title: String {
        switch self {
        case .running: return "运行中"
        case .thinking: return "思考中"
        case .executingCommand: return "执行命令"
        case .editingFiles: return "修改文件"
        case .readingFiles: return "读取内容"
        case .searching: return "搜索中"
        case .usingTool: return "执行工具"
        case .compacting: return "整理上下文"
        case .waitingForApproval: return "等待确认"
        case .waitingForInput: return "等待输入"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .thinking: return "ellipsis.bubble"
        case .executingCommand: return "terminal"
        case .editingFiles: return "pencil"
        case .readingFiles: return "doc.text"
        case .searching: return "magnifyingglass"
        case .usingTool: return "gearshape"
        case .compacting: return "arrow.down.right.and.arrow.up.left"
        case .waitingForApproval: return "hand.raised"
        case .waitingForInput: return "questionmark.bubble"
        }
    }

    var priority: Int {
        switch self {
        case .waitingForApproval: return 0
        case .waitingForInput: return 1
        default: return 2
        }
    }

    var needsAttention: Bool { priority < 2 }

    static func resolve(status: [String: Any]?, logActivity: TaskActivity) -> TaskActivity {
        guard status?["type"] as? String == "active",
              let flags = status?["activeFlags"] as? [String] else { return logActivity }
        if flags.contains("waitingOnApproval") { return .waitingForApproval }
        if flags.contains("waitingOnUserInput") { return .waitingForInput }
        // A current runtime status can clear an older waiting record from disk.
        return logActivity.needsAttention ? .running : logActivity
    }

    static func forTool(_ name: String) -> TaskActivity {
        if name == "web.run" { return .searching }
        switch name.split(separator: ".").last.map(String.init) ?? name {
        case "exec_command", "shell", "shell_command": return .executingCommand
        case "apply_patch": return .editingFiles
        case "read_file", "read_mcp_resource", "view_image": return .readingFiles
        case "web_search", "web__run": return .searching
        case "request_user_input": return .waitingForInput
        default: return .usingTool
        }
    }

    static func forItem(_ type: String) -> TaskActivity {
        switch type.lowercased() {
        case "reasoning": return .thinking
        case "commandexecution": return .executingCommand
        case "filechange": return .editingFiles
        case "websearch": return .searching
        case "contextcompaction": return .compacting
        default: return .usingTool
        }
    }

    static func elapsed(since start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let interval = max(0, now.timeIntervalSince(start))
        guard interval.isFinite, interval < Double(Int.max) else { return nil }
        let seconds = Int(interval)
        if seconds >= 3600 { return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分 \(seconds % 60) 秒" }
        if seconds >= 60 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds) 秒"
    }
}
