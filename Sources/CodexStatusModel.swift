import Combine
import Foundation
import UserNotifications

@MainActor
final class CodexStatusModel: ObservableObject {
    @Published private(set) var rateLimits: RateLimitSnapshot?

    var primaryLimit: RateLimitWindow? { rateLimits?.menuBarWindow }
    @Published private(set) var activeTasks: [ActiveTask] = []
    @Published private(set) var connectionMessage = "正在连接 Codex…"
    @Published private(set) var isConnected = false

    private let client = CodexAppServerClient()
    private var refreshTimer: Timer?
    private var quotaRefreshTimer: Timer?
    @Published private(set) var now = Date()
    @Published private(set) var quotaUpdatedAt: Date?
    @Published private(set) var tasksUpdatedAt: Date?
    private var clockTimer: Timer?
    @Published private(set) var quotaReadFailed = false
    @Published private(set) var tasksReadFailed = false

    var isQuotaStale: Bool {
        StatusTiming.isStale(connected: isConnected, updatedAt: quotaUpdatedAt,
                            failed: quotaReadFailed, maxAge: StatusTiming.quotaRefreshInterval + 30, now: now)
    }

    var isTasksStale: Bool {
        StatusTiming.isStale(connected: isConnected, updatedAt: tasksUpdatedAt,
                            failed: tasksReadFailed, maxAge: 30, now: now)
    }

    var freshnessText: String {
        guard let quotaUpdatedAt else { return "尚未成功读取额度" }
        let stamp = quotaUpdatedAt.formatted(date: .abbreviated, time: .standard)
        return "额度更新：\(stamp)" + (isQuotaStale ? " · 上次数据" : "")
    }

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
                if !connected {
                    self?.quotaReadFailed = true
                    self?.tasksReadFailed = true
                }
                self?.isConnected = connected
                self?.connectionMessage = message
                self?.now = Date()
            }
        }
        requestNotificationPermission()
        client.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: StatusTiming.taskRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.client.refresh(includeQuota: false)
            }
        }
        refreshTimer?.tolerance = 1
        quotaRefreshTimer = Timer.scheduledTimer(withTimeInterval: StatusTiming.quotaRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.client.refreshQuota() }
        }
        quotaRefreshTimer?.tolerance = 5
    }

    func setPanelVisible(_ visible: Bool) {
        clockTimer?.invalidate()
        clockTimer = nil
        now = Date()
        if visible {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            }
            refresh()
        }
    }

    func refresh() {
        client.refresh()
    }

    func restart() {
        connectionMessage = "正在重新连接…"
        isConnected = false
        quotaReadFailed = true
        tasksReadFailed = true
        now = Date()
        client.restart()
    }

    private func handle(_ message: CodexMessage) {
        switch message {
        case let .rateLimits(snapshot):
            rateLimits = snapshot
            quotaUpdatedAt = Date()
            quotaReadFailed = false
        case let .activeTasks(tasks):
            activeTasks = tasks
            tasksUpdatedAt = Date()
            tasksReadFailed = false
        case .quotaReadFailed:
            quotaReadFailed = true
        case .tasksReadFailed:
            tasksReadFailed = true
        case let .taskEnded(title, outcome):
            notifyCompletion(title: title, outcome: outcome)
        }
        now = Date()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyCompletion(title: String, outcome: TaskOutcome) {
        let content = UNMutableNotificationContent()
        content.title = outcome.notificationTitle
        content.body = String(title.prefix(160))
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
