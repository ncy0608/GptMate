import CoreFoundation
import Foundation

struct RateLimitBucket: Identifiable, Equatable {
    let id: String
    let name: String
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitSnapshot: Equatable {
    let buckets: [RateLimitBucket]

    // The first bucket is the legacy/default allowance, not the most exhausted model.
    var menuBarBucket: RateLimitBucket? { buckets.first }
    var menuBarWindow: RateLimitWindow? { menuBarBucket?.primary ?? menuBarBucket?.secondary }

    static func parse(_ container: [String: Any]) -> RateLimitSnapshot? {
        let legacy = container["rateLimits"] as? [String: Any]
        let all = container["rateLimitsByLimitId"] as? [String: Any]
        guard legacy != nil || all != nil else { return nil }

        var buckets = (all ?? [:]).compactMap { id, value -> RateLimitBucket? in
            guard let fields = value as? [String: Any] else { return nil }
            return parseBucket(fields, id: id)
        }
        // A full multi-bucket response is authoritative. Do not append its legacy mirror.
        if buckets.isEmpty, let legacy {
            buckets = [parseBucket(legacy, id: text(legacy["limitId"]) ?? "codex")]
        }
        let legacyID = legacy.flatMap { text($0["limitId"]) }
        let preferredID = buckets.contains(where: { $0.id == "codex" }) ? "codex" : legacyID
        buckets.sort {
            if ($0.id == preferredID) != ($1.id == preferredID) { return $0.id == preferredID }
            return $0.id < $1.id
        }
        return RateLimitSnapshot(buckets: buckets)
    }

    private static func parseBucket(_ fields: [String: Any], id: String) -> RateLimitBucket {
        RateLimitBucket(
            id: id,
            name: text(fields["limitName"]) ?? (id == "codex" ? "Codex" : id),
            primary: parseWindow(fields["primary"]),
            secondary: parseWindow(fields["secondary"])
        )
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let fields = value as? [String: Any], let used = number(fields["usedPercent"]) else { return nil }
        let minutes = number(fields["windowDurationMins"]).flatMap { value -> Int? in
            guard value > 0, value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMins: minutes,
            resetsAt: number(fields["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
