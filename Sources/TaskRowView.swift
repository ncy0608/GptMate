import SwiftUI

struct TaskRowView: View {
    let task: ActiveTask
    let now: Date
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(task.title, systemImage: "bolt.fill")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(task.title)
                Label(isStale ? "状态待更新" : task.activityKind.title,
                      systemImage: isStale ? "clock" : task.activityKind.symbol)
                    .font(.caption2)
                    .foregroundStyle(!isStale && task.activityKind.needsAttention ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .frame(width: 76, alignment: .leading)
                Group {
                    if let elapsed = TaskActivity.elapsed(since: task.startedAt, now: now) {
                        Text("本轮 \(elapsed)")
                            .monospacedDigit()
                            .help("从本轮任务开始计算，包含等待时间；数据过期时停留在上次更新时间。")
                    } else {
                        Text("时长未知")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 100, alignment: .trailing)
            }
            ForEach(task.steps.prefix(2)) { step in
                Label(step.step, systemImage: stepIcon(step.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func stepIcon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "inProgress": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }
}
