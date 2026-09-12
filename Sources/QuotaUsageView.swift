import AppKit
import SwiftUI

func quotaColor(remainingPercent: Double) -> NSColor {
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

struct QuotaUsageView: View {
    let snapshot: RateLimitSnapshot?
    let isStale: Bool
    let now: Date
    @State private var isSparkExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isStale {
                Text(snapshot == nil ? "额度待更新" : "额度 · 上次数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let snapshot, !snapshot.buckets.isEmpty {
                ForEach(snapshot.buckets) { bucket in
                    VStack(alignment: .leading, spacing: 8) {
                        let isSpark = bucket.id.localizedCaseInsensitiveContains("spark")
                            || bucket.name.localizedCaseInsensitiveContains("spark")
                        if isSpark {
                            Button {
                                isSparkExpanded.toggle()
                            } label: {
                                HStack {
                                    Text(bucket.name)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Image(systemName: isSparkExpanded ? "chevron.down" : "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.weight(.semibold))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(isSparkExpanded ? "已展开" : "已收起")
                            .accessibilityHint("点击展开或收起额度详情")
                        } else if bucket.id != "codex" {
                            Text(bucket.name)
                                .font(.caption.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !isSpark || isSparkExpanded {
                            if let primary = bucket.primary {
                                limitRow(primary, fallbackName: "主额度")
                            }
                            if let secondary = bucket.secondary {
                                limitRow(secondary, fallbackName: "次级额度")
                            }
                            if bucket.primary == nil && bucket.secondary == nil {
                                Text("暂未返回周期额度")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("暂未读取到额度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            isSparkExpanded = false
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
                    color: isStale ? Color.gray : Color(nsColor: quotaColor(remainingPercent: limit.remainingPercent))))
            if let reset = limit.resetsAt {
                Text(StatusTiming.countdown(to: reset, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("重置：\(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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

}
