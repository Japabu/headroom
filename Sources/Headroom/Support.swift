import AppKit
import ServiceManagement
import UserNotifications

enum TextMode: String, CaseIterable, Identifiable {
    case smart, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "When it matters"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var textMode: TextMode { didSet { defaults.set(textMode.rawValue, forKey: "textMode") } }
    @Published var notifyHot: Bool { didSet { defaults.set(notifyHot, forKey: "notifyHot") } }
    @Published var notifyLimit: Bool { didSet { defaults.set(notifyLimit, forKey: "notifyLimit") } }
    @Published var notifyRefill: Bool { didSet { defaults.set(notifyRefill, forKey: "notifyRefill") } }
    @Published var notifyUseIt: Bool { didSet { defaults.set(notifyUseIt, forKey: "notifyUseIt") } }
    @Published var renewLogins: Bool { didSet { defaults.set(renewLogins, forKey: "renewLogins") } }
    @Published var labels: [String: String] { didSet { defaults.set(labels, forKey: "labels") } }

    init() {
        defaults.register(defaults: ["textMode": "smart", "notifyHot": true, "notifyLimit": true,
                                     "notifyRefill": true, "notifyUseIt": false, "renewLogins": true])
        textMode = TextMode(rawValue: defaults.string(forKey: "textMode") ?? "") ?? .smart
        notifyHot = defaults.bool(forKey: "notifyHot")
        notifyLimit = defaults.bool(forKey: "notifyLimit")
        notifyRefill = defaults.bool(forKey: "notifyRefill")
        notifyUseIt = defaults.bool(forKey: "notifyUseIt")
        renewLogins = defaults.bool(forKey: "renewLogins")
        labels = defaults.dictionary(forKey: "labels") as? [String: String] ?? [:]
    }
}

/// Posts each notification at most once per key; keys carry the window's reset time,
/// so "once per window" survives restarts.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var enabled = true
    var onOpen: (() -> Void)?
    private var fired: [String: Date]
    private var useScript = false
    private let storeKey = "firedNotifications"

    override init() {
        let stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Date] ?? [:]
        fired = stored.filter { $0.value > Date().addingTimeInterval(-9 * 86400) }
        super.init()
    }

    static func windowKey(_ id: String, _ resets: Date) -> String { "\(id)|\(Int(resets.timeIntervalSince1970 / 60))" }

    func setup() {
        guard Bundle.main.bundleIdentifier != nil else { useScript = true; return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if error != nil { self?.useScript = true }
        }
    }

    func hasFired(_ key: String) -> Bool { fired[key] != nil }

    func post(key: String, title: String, body: String) {
        guard enabled, fired[key] == nil else { return }
        fired[key] = Date()
        UserDefaults.standard.set(fired, forKey: storeKey)
        if useScript { Self.script(title, body); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) { error in
            if error != nil { Self.script(title, body) }
        }
    }

    private static func script(_ title: String, _ body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        DispatchQueue.global().async {
            _ = Shell.run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpen?() }
        completionHandler()
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Headroom: login item change failed: \(error.localizedDescription)")
        }
    }

    static func registerOnFirstLaunch() {
        let key = "didRegisterLoginItem"
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: key) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// Last known numbers per account, so a restart shows something right away and an
/// account you're no longer logged in to still shows when it resets.
struct CachedAccount: Codable {
    var usage: Usage?
    var email: String?
    var plan: String?
    var org: String?
    var signedOut: Bool?
}

enum Cache {
    // v1 was keyed by keychain slot, which mixed up accounts after a /login. v2 is keyed by account.
    private static let key = "cache.v2"

    static func load() -> [String: CachedAccount] {
        UserDefaults.standard.removeObject(forKey: "cache.v1")
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedAccount].self, from: data)) ?? [:]
    }

    static func save(_ cache: [String: CachedAccount]) {
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum Fmt {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEjmm")
        return f
    }()
    /// "21 Oct 13:00". The combined template would add "at", which wraps in the menu.
    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        let day = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0, locale: .current) ?? "d MMM"
        let time = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current) ?? "HH:mm"
        f.dateFormat = day + " " + time
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    static func time(_ d: Date) -> String { time.string(from: d) }

    /// "14:20" today, "Tue 20:00" this week, "19 Oct 20:00" after that.
    /// Rounded to the minute: resets arrive as 19:59:59.75 and should read 20:00.
    static func when(_ date: Date, now: Date) -> String {
        let d = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        if Calendar.current.isDate(d, inSameDayAs: now) { return time.string(from: d) }
        if d.timeIntervalSince(now) < 6 * 86400 { return dayTime.string(from: d) }
        return dateTime.string(from: d)
    }

    /// "2 h 19 m", "42 m", "1 d 8 h".
    static func duration(_ t: TimeInterval) -> String {
        let m = max(0, Int((t / 60).rounded(.up)))
        if m >= 1440 {
            let h = (m % 1440) / 60
            return h > 0 ? "\(m / 1440) d \(h) h" : "\(m / 1440) d"
        }
        if m >= 60 { return "\(m / 60) h \(String(format: "%02d", m % 60)) m" }
        return "\(m) m"
    }

    /// Menu bar countdown: "2:19", or "42m" under an hour.
    static func countdown(_ t: TimeInterval) -> String {
        let m = max(0, Int((t / 60).rounded(.up)))
        return m >= 60 ? String(format: "%d:%02d", m / 60, m % 60) : "\(m)m"
    }

    /// Countdown within a day, weekday after that.
    static func short(until d: Date, now: Date) -> String {
        let t = d.timeIntervalSince(now)
        return t < 86400 ? countdown(t) : weekday.string(from: d)
    }
}
