import AppKit
import Combine
import SwiftUI

@main
struct CodexMeterApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusSubscription: AnyCancellable?
    private var wakeSubscription: AnyCancellable?
    private var lastRingPercent: Double?
    private var lastRingStale: Bool?
    private lazy var model = CodexStatusModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.delegate = self
        wakeSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.refresh() }
        let hostingController = NSHostingController(rootView: MenuContentView(model: model))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        statusSubscription = Publishers.CombineLatest3(model.$activeTasks, model.$rateLimits, model.$now)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks, snapshot, _ in
                guard let self, let button = self.statusItem?.button else { return }
                let limit = snapshot?.menuBarWindow
                let title = "任务运行 \(tasks.count)"
                let remaining = limit.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "…"
                let stale = self.model.isQuotaStale || limit == nil
                let percent = limit?.remainingPercent ?? 0
                if self.lastRingPercent != percent || self.lastRingStale != stale {
                    button.image = self.quotaRing(remainingPercent: percent, stale: stale)
                    self.lastRingPercent = percent
                    self.lastRingStale = stale
                }
                let displayedTitle = self.model.isTasksStale ? "任务状态待更新" : (limit == nil ? "\(title) · …" : title)
                if button.title != displayedTitle { button.title = displayedTitle }
                let quotaName = snapshot?.menuBarBucket?.name ?? "额度"
                let accessibilityLabel = "\(displayedTitle) · \(quotaName) 剩余 \(remaining) · \(self.model.freshnessText)"
                if button.accessibilityLabel() != accessibilityLabel {
                    button.setAccessibilityLabel(accessibilityLabel)
                }
            }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.setPanelVisible(true)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPanelVisible(false)
    }

    private func quotaRing(remainingPercent: Double, stale: Bool) -> NSImage {
        let remaining = min(100, max(0, remainingPercent))
        let color = stale ? NSColor.systemGray : quotaColor(remainingPercent: remaining)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let track = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
            track.lineWidth = remaining == 0 ? 1.5 : 2.5
            let trackColor = remaining == 0
                ? color
                : NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.96, alpha: 1)
            trackColor.setStroke()
            track.stroke()

            let progress = stale ? 1 : remaining / 100
            if progress > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = 2.5
                arc.lineCapStyle = .butt
                arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 7,
                              startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuContentView: View {
    @ObservedObject var model: CodexStatusModel
    @State private var contentHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    usage
                    Divider()
                    tasks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(height: min(contentHeight, 440))
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.connectionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(model.isConnected ? Color.green : Color.gray)
                .frame(width: 9, height: 9)
        }
    }

    private var usage: some View {
        QuotaUsageView(snapshot: model.rateLimits, isStale: model.isQuotaStale,
                       now: model.now)
    }

    @ViewBuilder
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.activeTasks.isEmpty {
                Text(model.isTasksStale ? "任务状态待更新" : "暂无活动任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.isTasksStale ? "任务 · 上次数据 \(model.activeTasks.count)" : "活动任务 \(model.activeTasks.count)")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.activeTasks.prefix(5)) { task in
                    TaskRowView(task: task,
                                now: model.isTasksStale ? (model.tasksUpdatedAt ?? model.now) : model.now,
                                isStale: model.isTasksStale)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("刷新") { model.refresh() }
            Button("重连") { model.restart() }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
    }

}
