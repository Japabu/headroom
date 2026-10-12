import Foundation

struct Account: Identifiable, Hashable {
    let item: KeychainItem
    var configDir: URL?
    var globalConfig: URL?

    var id: String { item.service }
    var isDefault: Bool { item.service == Keychain.baseService }
}

/// Finds Claude Code logins and matches each to its config folder.
enum Discovery {
    struct Activity { var last: Date?; var running: Int }
    struct Found { var account: Account; var activity: Activity; var email: String? }

    static func accounts(extraDirs: [String]) -> [Account] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        for (base, prefix) in [(home, ".claude"), (home.appendingPathComponent(".config"), "claude")] {
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.lowercased().hasPrefix(prefix) {
                var isDir: ObjCBool = false
                let url = base.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { candidates.append(url) }
            }
        }
        candidates += extraDirs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        var bySuffix: [String: URL] = [:]
        for dir in candidates {
            for variant in [dir.path, dir.path + "/"] { bySuffix[Keychain.suffix(forConfigDir: variant)] = dir }
        }

        return Keychain.claudeItems().map { item in
            if item.service == Keychain.baseService {
                return Account(item: item, configDir: home.appendingPathComponent(".claude"),
                               globalConfig: home.appendingPathComponent(".claude.json"))
            }
            let dir = bySuffix[String(item.service.suffix(8))]
            return Account(item: item, configDir: dir, globalConfig: dir?.appendingPathComponent(".claude.json"))
        }
    }

    /// Last time Claude Code did something in this folder, and how many of its sessions are running.
    static func activity(_ dir: URL?) -> Activity {
        guard let dir else { return Activity(last: nil, running: 0) }
        let fm = FileManager.default
        var last = modified(dir.appendingPathComponent("history.jsonl"))
        var running = 0
        let sessions = dir.appendingPathComponent("sessions")
        for name in (try? fm.contentsOfDirectory(atPath: sessions.path)) ?? [] where name.hasSuffix(".json") {
            if let m = modified(sessions.appendingPathComponent(name)), m > (last ?? .distantPast) { last = m }
            if let pid = Int32(name.dropLast(5)), pid > 0, kill(pid, 0) == 0 { running += 1 }
        }
        return Activity(last: last, running: running)
    }

    static func email(_ globalConfig: URL?) -> String? {
        guard let url = globalConfig, let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    /// "Personal" for the plain `claude` login, "Work" for ~/.claude-work, else the email name.
    static func defaultLabel(_ account: Account, email: String?) -> String {
        if account.isDefault { return "Personal" }
        if let dir = account.configDir {
            var name = dir.lastPathComponent
            for prefix in [".claude", "claude"] where name.lowercased().hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                break
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
            if !name.isEmpty { return name.prefix(1).uppercased() + name.dropFirst() }
        }
        if let email, let local = email.split(separator: "@").first { return String(local) }
        return "Account " + account.item.service.suffix(4)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
