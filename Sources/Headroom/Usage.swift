import Foundation

/// One rate-limit window as Anthropic reports it: the 5-hour session, the week, or a per-model week.
struct UsageWindow: Codable, Hashable, Identifiable {
    var id: String
    var kind: String
    var label: String
    var percent: Double
    var resetsAt: Date?
    var severity: String?
    var length: TimeInterval

    static let sessionLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 86400

    var left: Double { max(0, 100 - percent) }
    var isLimited: Bool { percent >= 99.95 }
    var isSessionLength: Bool { length <= Self.sessionLength }
    var serverWarns: Bool { severity.map { $0 != "normal" } ?? false }

    /// The window as it stands at `now`. Once the reset time passes it is empty again,
    /// even before the next fetch confirms it.
    func at(_ now: Date) -> UsageWindow {
        guard let r = resetsAt, r <= now else { return self }
        var w = self
        w.percent = 0
        w.severity = nil
        w.resetsAt = nil
        return w
    }

    /// How far through the window we are, 0...1.
    func elapsed(_ now: Date) -> Double? {
        guard let r = resetsAt else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSince(now) / length))
    }

    /// Where usage lands at the reset if the current rate holds.
    func projected(_ now: Date) -> Double? {
        guard let e = elapsed(now), e >= 0.05 else { return nil }
        return percent / e
    }

    /// When usage hits 100% at the current rate, if that comes before the reset.
    /// Early in a window the rate is too noisy to say, so wait for 20% of the window or 50% used.
    func runsOut(_ now: Date) -> Date? {
        guard let r = resetsAt, percent > 0, !isLimited,
              percent >= 50 || (elapsed(now) ?? 0) >= 0.2 else { return nil }
        let elapsedSeconds = length - r.timeIntervalSince(now)
        guard elapsedSeconds > 120 else { return nil }
        let t = now.addingTimeInterval(left / (percent / elapsedSeconds))
        return t < r ? t : nil
    }

    /// Session rule: 20% or less left, or on pace to run out before the reset.
    func isHot(_ now: Date) -> Bool {
        guard !isLimited else { return false }
        if left <= 20 || serverWarns { return true }
        if percent >= 50, let p = projected(now), p >= 100 { return true }
        return false
    }

    /// Week rule: 15% or less left.
    var isLow: Bool { !isLimited && (left <= 15 || serverWarns) }
}

struct Usage: Codable, Hashable {
    var session: UsageWindow?
    var week: UsageWindow?
    var extras: [UsageWindow]
    var fetchedAt: Date

    var all: [UsageWindow] { [session, week].compactMap { $0 } + extras }

    func at(_ now: Date) -> Usage {
        Usage(session: session?.at(now), week: week?.at(now), extras: extras.map { $0.at(now) }, fetchedAt: fetchedAt)
    }
}

/// Reads the reply of /api/oauth/usage. The endpoint isn't a published API, so this
/// accepts both the `limits` list and the older `five_hour` / `seven_day` fields,
/// and throws rather than guessing when neither is there.
enum UsageParser {
    struct Failure: Error {}

    static func parse(_ data: Data, now: Date = Date()) throws -> Usage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure() }
        var session: UsageWindow?
        var week: UsageWindow?
        var extras: [UsageWindow] = []

        if let limits = root["limits"] as? [[String: Any]] {
            for (i, l) in limits.enumerated() {
                guard let pct = number(l["percent"]) else { continue }
                let kind = l["kind"] as? String ?? "limit"
                let resets = date(l["resets_at"])
                let severity = l["severity"] as? String
                switch kind {
                case "session":
                    session = UsageWindow(id: "session", kind: kind, label: "Session", percent: pct, resetsAt: resets,
                                          severity: severity, length: UsageWindow.sessionLength)
                case "weekly_all":
                    week = UsageWindow(id: "week", kind: kind, label: "Week", percent: pct, resetsAt: resets,
                                       severity: severity, length: UsageWindow.weekLength)
                default:
                    let isSession = (l["group"] as? String) == "session"
                    extras.append(UsageWindow(id: "\(kind)-\(i)", kind: kind, label: scopeName(l["scope"]) ?? prettify(kind),
                                              percent: pct, resetsAt: resets, severity: severity,
                                              length: isSession ? UsageWindow.sessionLength : UsageWindow.weekLength))
                }
            }
        }
        if session == nil, let w = root["five_hour"] as? [String: Any], let u = number(w["utilization"]) {
            session = UsageWindow(id: "session", kind: "session", label: "Session", percent: u, resetsAt: date(w["resets_at"]),
                                  severity: nil, length: UsageWindow.sessionLength)
        }
        if week == nil, let w = root["seven_day"] as? [String: Any], let u = number(w["utilization"]) {
            week = UsageWindow(id: "week", kind: "weekly_all", label: "Week", percent: u, resetsAt: date(w["resets_at"]),
                               severity: nil, length: UsageWindow.weekLength)
        }
        guard session != nil || week != nil else { throw Failure() }
        return Usage(session: session, week: week, extras: extras, fetchedAt: now)
    }

    static func number(_ v: Any?) -> Double? {
        // `v is Bool` would also match the numbers 0 and 1, so check for a real JSON boolean.
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// "2026-10-12T12:19:59.756633+00:00" – ISO8601DateFormatter can't take six fraction digits, so drop them.
    static func date(_ v: Any?) -> Date? {
        guard var s = v as? String else { return nil }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func scopeName(_ v: Any?) -> String? {
        guard let scope = v as? [String: Any] else { return nil }
        for key in ["model", "surface"] {
            if let m = scope[key] as? [String: Any], let n = (m["display_name"] as? String) ?? (m["id"] as? String) { return n }
            if let n = scope[key] as? String { return n }
        }
        return nil
    }

    static func prettify(_ kind: String) -> String {
        let s = kind.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}
