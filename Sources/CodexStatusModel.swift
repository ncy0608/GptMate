import Combine
import Foundation
import UserNotifications

@MainActor
final class CodexStatusModel: ObservableObject {
    @Published private(set) var primaryLimit: RateLimitWindow?
    @Published private(set) var secondaryLimit: RateLimitWindow?
    @Published private(set) var activeTasks: [ActiveTask] = []
    @Published private(set) var connectionMessage = "正在连接 Codex…"
    @Published private(set) var isConnected = false

    private let client = CodexAppServerClient()
    private var refreshTimer: Timer?
    private var hasReceivedInitialTasks = false

    var menuBarTitle: String {
        let remaining = primaryLimit.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "…"
        return "任务运行 \(activeTasks.count) · \(remaining)"
    }

    init() {
        client.onMessage = { [weak self] message in
            DispatchQueue.main.async { self?.handle(message) }
        }
        client.onConnectionChange = { [weak self] connected, message in
            DispatchQueue.main.async {
                self?.isConnected = connected
                self?.connectionMessage = message
            }
        }
        requestNotificationPermission()
        client.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.client.refresh() }
        }
    }

    func refresh() {
        connectionMessage = "正在刷新…"
        client.refresh()
    }

    func restart() {
        connectionMessage = "正在重新连接…"
        client.restart()
    }

    private func handle(_ message: CodexMessage) {
        switch message {
        case let .rateLimits(primary, secondary):
            primaryLimit = primary
            secondaryLimit = secondary
        case let .activeTasks(tasks):
            if hasReceivedInitialTasks {
                let newIDs = Set(tasks.map(\.threadID))
                for completed in activeTasks where !newIDs.contains(completed.threadID) {
                    notifyCompletion(title: completed.title)
                }
            }
            activeTasks = tasks
            hasReceivedInitialTasks = true
        }
        if isConnected {
            connectionMessage = "已连接 Codex"
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyCompletion(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 任务完成"
        content.body = String(title.prefix(160))
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
