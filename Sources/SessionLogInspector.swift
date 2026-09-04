import Foundation

enum SessionLogInspector {
    private static let chunkSize: UInt64 = 64 * 1024
    private static let activityTailSize: UInt64 = 2 * 1024 * 1024

    private static let lifecyclePatterns: [(data: Data, active: Bool)] = [
        (Data("\"type\":\"task_started\"".utf8), true),
        (Data("\"type\":\"task_complete\"".utf8), false),
        (Data("\"type\":\"turn_aborted\"".utf8), false),
    ]

    static func inspect(path: String) -> SessionLogState? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let active = latestLifecycleState(handle: handle, fileSize: fileSize)
        guard let active else { return nil }

        let activity = active ? latestReasoning(handle: handle, fileSize: fileSize) : nil
        return SessionLogState(active: active, activity: activity)
    }

    private static func latestLifecycleState(handle: FileHandle, fileSize: UInt64) -> Bool? {
        let overlapSize = lifecyclePatterns.map(\.data.count).max() ?? 0
        var end = fileSize
        var higherBlockPrefix = Data()

        while end > 0 {
            let start = end > chunkSize ? end - chunkSize : 0
            do {
                try handle.seek(toOffset: start)
                var block = try handle.read(upToCount: Int(end - start)) ?? Data()
                block.append(higherBlockPrefix)

                var latestMatch: (offset: Int, active: Bool)?
                for pattern in lifecyclePatterns {
                    guard let range = block.range(of: pattern.data, options: .backwards) else {
                        continue
                    }
                    if latestMatch == nil || range.lowerBound > latestMatch!.offset {
                        latestMatch = (range.lowerBound, pattern.active)
                    }
                }

                if let latestMatch {
                    return latestMatch.active
                }

                higherBlockPrefix = Data(block.prefix(max(0, overlapSize - 1)))
                end = start
            } catch {
                return nil
            }
        }

        return nil
    }

    private static func latestReasoning(handle: FileHandle, fileSize: UInt64) -> String? {
        let start = fileSize > activityTailSize ? fileSize - activityTailSize : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)

            for line in lines.reversed() {
                guard line.count < 256 * 1024,
                      line.range(of: Data("\"type\":\"agent_reasoning\"".utf8)) != nil,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let dictionary = object as? [String: Any],
                      let payload = dictionary["payload"] as? [String: Any],
                      let text = payload["text"] as? String else {
                    continue
                }

                let cleaned = text
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                return String(cleaned.prefix(180))
            }
        } catch {
            return nil
        }

        return nil
    }
}
