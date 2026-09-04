import AppKit
import Combine
import SwiftUI

private func quotaColor(remainingPercent: Double) -> NSColor {
    if remainingPercent > 30 {
        return NSColor(srgbRed: 40.0 / 255, green: 205.0 / 255, blue: 65.0 / 255, alpha: 1)
    } else if remainingPercent > 10 {
        return NSColor(srgbRed: 1, green: 204.0 / 255, blue: 0, alpha: 1)
    } else {
        return NSColor(srgbRed: 1, green: 59.0 / 255, blue: 48.0 / 255, alpha: 1)
    }
}

private struct QuotaProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 6)
    }
}

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
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusSubscription: AnyCancellable?
    private lazy var model = CodexStatusModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuContentView(model: model))

        statusSubscription = Publishers.CombineLatest(model.$activeTasks, model.$primaryLimit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks, limit in
                guard let self, let button = self.statusItem?.button else { return }
                let title = "任务运行 \(tasks.count)"
                let remaining = limit.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "…"
                button.title = limit == nil ? "\(title) · …" : title
                button.image = limit.map { self.quotaRing(remainingPercent: $0.remainingPercent) }
                button.toolTip = "\(title) · 剩余 \(remaining)"
                button.setAccessibilityLabel(button.toolTip)
            }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func quotaRing(remainingPercent: Double) -> NSImage {
        let remaining = min(100, max(0, remainingPercent))
        let color = quotaColor(remainingPercent: remaining)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let track = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
            track.lineWidth = remaining == 0 ? 1.5 : 2.5
            let trackColor = remaining == 0
                ? color
                : NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.96, alpha: 1)
            trackColor.setStroke()
            track.stroke()

            let progress = remaining / 100
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            usage
            Divider()
            tasks
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GptMate")
                    .font(.headline)
                Text(model.connectionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.isConnected ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private var usage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("额度")
                .font(.subheadline.weight(.semibold))
            if let primary = model.primaryLimit {
                limitRow(primary, fallbackName: "Codex")
            } else {
                Text("暂未读取到额度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let secondary = model.secondaryLimit {
                limitRow(secondary, fallbackName: "次级额度")
            }
        }
    }

    private func limitRow(_ limit: RateLimitWindow, fallbackName: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(limitName(limit, fallback: fallbackName))
                Spacer()
                Text("剩余 \(Int(limit.remainingPercent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(limit.remainingPercent == 0
                        ? Color(nsColor: quotaColor(remainingPercent: 0)) : Color.primary)
            }
            .font(.caption)
            ProgressView(value: limit.remainingPercent, total: 100)
                .progressViewStyle(QuotaProgressStyle(
                    color: Color(nsColor: quotaColor(remainingPercent: limit.remainingPercent))))
            if let reset = limit.resetsAt {
                Text("重置：\(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正在运行 \(model.activeTasks.count)")
                .font(.subheadline.weight(.semibold))
            if model.activeTasks.isEmpty {
                Text("暂无活动任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.activeTasks.prefix(5)) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(task.title, systemImage: "bolt.fill")
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                        ForEach(task.steps.prefix(2)) { step in
                            Label(step.step, systemImage: stepIcon(step.status))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
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

    private func limitName(_ limit: RateLimitWindow, fallback: String) -> String {
        guard let minutes = limit.windowDurationMins else { return fallback }
        if minutes.isMultiple(of: 1440) {
            return "\(minutes / 1440) 天额度"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60) 小时额度"
        }
        return "\(minutes) 分钟额度"
    }

    private func stepIcon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "inProgress": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }
}
