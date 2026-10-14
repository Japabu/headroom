import Foundation

/// A place where Claude Code keeps one login: ~/.claude, or a CLAUDE_CONFIG_DIR folder.
/// Each `/login` replaces whatever account the slot held before.
struct LoginSlot: Identifiable, Hashable {
    let item: KeychainItem
    var configDir: URL?
    var globalConfig: URL?

    var id: String { item.service }
}

/// Finds Claude Code's login slots and what Claude Code is doing in each.
enum Discovery {
    struct Activity { var last: Date?; var running: Int }
    struct Found { var slot: LoginSlot; var activity: Activity }

    static func slots(extraDirs: [String]) -> [LoginSlot] {
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
                return LoginSlot(item: item, configDir: home.appendingPathComponent(".claude"),
                                 globalConfig: home.appendingPathComponent(".claude.json"))
            }
            let dir = bySuffix[String(item.service.suffix(8))]
            return LoginSlot(item: item, configDir: dir, globalConfig: dir?.appendingPathComponent(".claude.json"))
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

    /// The account Claude Code says this slot is logged in to, from its .claude.json.
    /// Only a fallback: it can lag a moment behind the keychain right after a /login.
    static func identity(_ globalConfig: URL?) -> Identity? {
        guard let url = globalConfig, let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let uuid = account["accountUuid"] as? String else { return nil }
        return Identity(key: "\(uuid)|\(account["organizationUuid"] as? String ?? "")",
                        email: account["emailAddress"] as? String, org: account["organizationName"] as? String)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
