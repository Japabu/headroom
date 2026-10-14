import Foundation
import Security
import CryptoKit

enum Shell {
    struct Result { var code: Int32; var out: Data }

    static func run(_ path: String, _ args: [String], input: Data? = nil, timeout: TimeInterval = 10) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let inPipe = input == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice
        do { try p.run() } catch { return Result(code: -1, out: Data()) }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(code: p.terminationStatus, out: data)
    }
}

struct KeychainItem: Hashable {
    let service: String
    let account: String
}

/// Claude Code keeps each login as a generic password named "Claude Code-credentials",
/// plus "-<first 8 hex of sha256(config dir)>" when CLAUDE_CONFIG_DIR is set.
/// Reads and writes go through /usr/bin/security, like Claude Code's own, so the
/// keychain never asks for permission.
enum Keychain {
    static let baseService = "Claude Code-credentials"
    /// Headroom's own copy of each login it has seen, so an account can still be tracked
    /// after Claude Code is switched to another one with /login.
    static let copyService = "Headroom saved login"

    static func copyItem(_ key: String) -> KeychainItem { KeychainItem(service: copyService, account: key) }
    private static let security = "/usr/bin/security"

    /// Lists Claude Code logins. Asking only for attributes never shows a keychain prompt.
    static func claudeItems() -> [KeychainItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        var byService: [String: KeychainItem] = [:]
        for row in rows {
            guard let service = row[kSecAttrService as String] as? String, isClaude(service) else { continue }
            let account = row[kSecAttrAccount as String] as? String ?? NSUserName()
            if byService[service] == nil || account == NSUserName() {
                byService[service] = KeychainItem(service: service, account: account)
            }
        }
        return byService.values.sorted { $0.service < $1.service }
    }

    static func isClaude(_ service: String) -> Bool {
        if service == baseService { return true }
        let prefix = baseService + "-"
        guard service.hasPrefix(prefix) else { return false }
        let suffix = service.dropFirst(prefix.count)
        return suffix.count == 8 && suffix.allSatisfy(\.isHexDigit)
    }

    static func suffix(forConfigDir path: String) -> String {
        let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    static func read(_ item: KeychainItem) -> [String: Any]? {
        let r = Shell.run(security, ["find-generic-password", "-a", item.account, "-w", "-s", item.service])
        guard r.code == 0 else { return nil }
        var text = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{"), let decoded = Data(hex: text) { text = String(decoding: decoded, as: UTF8.self) }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func write(_ item: KeychainItem, _ object: [String: Any]) -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return false }
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(item.account)\" -s \"\(item.service)\" -X \"\(hex)\"\n"
        let r: Shell.Result
        if command.utf8.count <= 4032 {
            r = Shell.run(security, ["-i"], input: Data(command.utf8))
        } else {
            r = Shell.run(security, ["add-generic-password", "-U", "-a", item.account, "-s", item.service, "-X", hex])
        }
        return r.code == 0
    }
}

struct OAuthCreds {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var subscriptionType: String?
    var rateLimitTier: String?

    init?(_ root: [String: Any]) {
        guard let o = root["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty else { return nil }
        accessToken = token
        refreshToken = o["refreshToken"] as? String
        expiresAt = (o["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        scopes = o["scopes"] as? [String] ?? []
        subscriptionType = o["subscriptionType"] as? String
        rateLimitTier = o["rateLimitTier"] as? String
    }

    var expiresSoon: Bool { expiresAt.map { $0 < Date().addingTimeInterval(60) } ?? false }

    /// Changes whenever the access token does, i.e. on every renewal or /login.
    var fingerprint: String {
        String(SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The claudeAiOauth fields, in the shape Claude Code stores them.
    var dictionary: [String: Any] {
        var d: [String: Any] = ["accessToken": accessToken, "scopes": scopes]
        if let refreshToken { d["refreshToken"] = refreshToken }
        if let expiresAt { d["expiresAt"] = Int64(expiresAt.timeIntervalSince1970 * 1000) }
        if let subscriptionType { d["subscriptionType"] = subscriptionType }
        if let rateLimitTier { d["rateLimitTier"] = rateLimitTier }
        return d
    }

    /// "default_claude_max_20x" → "Max 20x", "pro" → "Pro".
    var plan: String? {
        if let tier = rateLimitTier?.lowercased(),
           let r = tier.range(of: #"max_\d+x"#, options: .regularExpression) {
            return "Max " + tier[r].dropFirst(4)
        }
        guard let s = subscriptionType, !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

enum API {
    enum Failure: Error { case unauthorized, rateLimited(TimeInterval?), http(Int), network }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    static func usage(token: String) async -> Result<Data, Failure> {
        await send(authorized(usageURL, token), authCodes: [401, 403])
    }

    /// Whose login a token is: the account plus the organization, since one person can
    /// have a personal plan and a team plan with separate limits.
    static func identity(token: String) async -> Identity? {
        guard case .success(let data) = await send(authorized(profileURL, token), authCodes: [401, 403]),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["account"] as? [String: Any],
              let uuid = account["uuid"] as? String else { return nil }
        let org = root["organization"] as? [String: Any]
        return Identity(key: "\(uuid)|\(org?["uuid"] as? String ?? "")",
                        email: account["email"] as? String, org: org?["name"] as? String)
    }

    struct Token: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let refresh_token_expires_in: Double?
        let scope: String?
    }

    static func refresh(_ refreshToken: String, scopes: [String]) async -> Result<Token, Failure> {
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
        if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var r = URLRequest(url: tokenURL)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        switch await send(r, authCodes: [400, 401, 403]) {
        case .success(let data):
            guard let t = try? JSONDecoder().decode(Token.self, from: data) else { return .failure(.http(200)) }
            return .success(t)
        case .failure(let f):
            return .failure(f)
        }
    }

    private static func authorized(_ url: URL, _ token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private static func send(_ request: URLRequest, authCodes: Set<Int>) async -> Result<Data, Failure> {
        var r = request
        r.setValue("Headroom/1.0 (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: r)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if (200..<300).contains(code) { return .success(data) }
            if authCodes.contains(code) { return .failure(.unauthorized) }
            if code == 429 {
                return .failure(.rateLimited((http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)))
            }
            return .failure(.http(code))
        } catch {
            return .failure(.network)
        }
    }
}

enum AccountIssue: Equatable {
    case expiredClaudeRunning, expiredRenewOff, expiredRenewFailed, notLoggedIn
    case offline, rateLimited, unreadable, renewNotSaved, signedOut

    var message: String {
        switch self {
        case .expiredClaudeRunning: "Login expired. Claude Code is open with this account and renews it the next time you use it."
        case .expiredRenewOff: "Login expired. Use this account in Claude Code once to renew it, or turn on renewing in Settings."
        case .expiredRenewFailed: "Login expired and couldn't be renewed. Run /login in Claude Code for this account."
        case .notLoggedIn: "No saved login. Run /login in Claude Code for this account."
        case .offline: "Can't reach Anthropic right now. Retrying soon."
        case .rateLimited: "Anthropic asked Headroom to slow down. Retrying in a few minutes."
        case .unreadable: "The usage reply changed format, so Headroom can't read it. It needs an update."
        case .renewNotSaved: "Renewed the login but couldn't save it. If Claude Code asks you to log in again, run /login."
        case .signedOut: "This login stopped working, so these are the last known numbers. Log in to this account with /login once to track it again."
        }
    }

    var short: String {
        switch self {
        case .expiredClaudeRunning, .expiredRenewOff, .expiredRenewFailed: "Login expired"
        case .notLoggedIn: "Not logged in"
        case .offline: "Offline"
        case .rateLimited: "Slowed down, retrying"
        case .unreadable: "Can't read usage"
        case .renewNotSaved: "Login renewed but not saved"
        case .signedOut: "Last known numbers"
        }
    }
}

/// Whose login something is. `key` is "accountUUID|organizationUUID".
struct Identity: Codable, Hashable {
    var key: String
    var email: String?
    var org: String?
}

/// One round trip for one login: read it, find out whose it is, renew it if needed and
/// allowed, and ask for usage.
enum Fetcher {
    enum Source {
        /// A Claude Code slot. Claude Code owns this login.
        case slot(LoginSlot, claudeRunning: Bool)
        /// Headroom's saved copy of an account that no slot holds anymore.
        case copy(Identity)
    }

    struct Outcome {
        var usage: Usage?
        var issue: AccountIssue?
        var plan: String?
        var identity: Identity?
        var fingerprint: String?
        var retryAfter: TimeInterval?
    }

    /// `known` is the identity found the last time this slot had the same token, which
    /// saves asking Anthropic again. `keepCopy` saves the login under Headroom's own entry.
    static func run(_ source: Source, known: (fingerprint: String, identity: Identity)?,
                    renewAllowed: Bool, keepCopy: Bool = true) async -> Outcome {
        var out = Outcome()
        let item: KeychainItem
        var claudeRunning = false
        var isCopy = false
        switch source {
        case .slot(let slot, let running):
            item = slot.item
            claudeRunning = running
        case .copy(let identity):
            item = Keychain.copyItem(identity.key)
            isCopy = true
            out.identity = identity
        }

        guard let root = Keychain.read(item), var creds = OAuthCreds(root) else {
            out.issue = isCopy ? .signedOut : .notLoggedIn
            return out
        }
        out.plan = creds.plan
        out.fingerprint = creds.fingerprint
        if out.identity == nil, let known, known.fingerprint == creds.fingerprint { out.identity = known.identity }

        // Never renew under a running Claude Code: it holds the same refresh token, and a
        // renewal here would invalidate it. Claude Code renews on its own when it's used.
        let canRenew = renewAllowed && !claudeRunning && creds.refreshToken != nil
        let expiredIssue: AccountIssue = claudeRunning ? .expiredClaudeRunning
            : !renewAllowed ? .expiredRenewOff : isCopy ? .signedOut : .expiredRenewFailed

        func renewNow() async -> Bool {
            switch await renew(item, creds) {
            case .ok(let c, let saved):
                creds = c
                out.fingerprint = c.fingerprint
                if !saved { out.issue = .renewNotSaved }
                return true
            case .failed(let issue):
                out.issue = issue == .expiredRenewFailed ? expiredIssue : issue
                return false
            }
        }

        if creds.expiresSoon {
            guard canRenew else {
                if case .slot(let slot, _) = source, out.identity == nil { out.identity = Discovery.identity(slot.globalConfig) }
                out.issue = expiredIssue
                return out
            }
            guard await renewNow() else { return out }
        }

        // A new token (a /login, or a renewal) means asking again whose it is, and saving
        // a copy so the account can still be tracked after Claude Code switches away from it.
        if case .slot = source, out.identity == nil || out.fingerprint != known?.fingerprint {
            guard let identity = await API.identity(token: creds.accessToken) else {
                out.identity = nil
                if out.issue == nil { out.issue = .offline }
                return out
            }
            out.identity = identity
            if keepCopy { _ = Keychain.write(Keychain.copyItem(identity.key), ["claudeAiOauth": creds.dictionary]) }
        }

        var result = await API.usage(token: creds.accessToken)
        if case .failure(.unauthorized) = result, canRenew, await renewNow() {
            result = await API.usage(token: creds.accessToken)
        }

        switch result {
        case .success(let data):
            do { out.usage = try UsageParser.parse(data) } catch { out.issue = .unreadable }
        case .failure(.unauthorized):
            if out.issue == nil { out.issue = expiredIssue }
        case .failure(.rateLimited(let after)):
            out.issue = .rateLimited
            out.retryAfter = after
        case .failure:
            out.issue = .offline
        }
        return out
    }

    enum Renewal { case ok(OAuthCreds, saved: Bool), failed(AccountIssue) }

    static func renew(_ item: KeychainItem, _ creds: OAuthCreds) async -> Renewal {
        // Claude Code may have renewed it a moment ago.
        if let latest = Keychain.read(item).flatMap({ OAuthCreds($0) }),
           latest.accessToken != creds.accessToken, !latest.expiresSoon {
            return .ok(latest, saved: true)
        }
        guard let refreshToken = creds.refreshToken else { return .failed(.expiredRenewFailed) }
        let token: API.Token
        switch await API.refresh(refreshToken, scopes: creds.scopes) {
        case .success(let t): token = t
        case .failure(.unauthorized): return .failed(.expiredRenewFailed)
        case .failure: return .failed(.offline)
        }

        var fresh = creds
        fresh.accessToken = token.access_token
        fresh.refreshToken = token.refresh_token ?? refreshToken
        fresh.expiresAt = Date().addingTimeInterval(token.expires_in ?? 3600)

        // Save into the same item, changing only the claudeAiOauth fields. Re-read right
        // before writing so anything else Claude Code stores there is kept as it is.
        guard var root = Keychain.read(item), var o = root["claudeAiOauth"] as? [String: Any] else {
            return .ok(fresh, saved: false)
        }
        o["accessToken"] = fresh.accessToken
        o["refreshToken"] = fresh.refreshToken
        o["expiresAt"] = Int64((fresh.expiresAt ?? Date()).timeIntervalSince1970 * 1000)
        if let s = token.refresh_token_expires_in { o["refreshTokenExpiresAt"] = Int64((Date().timeIntervalSince1970 + s) * 1000) }
        if let scope = token.scope { o["scopes"] = scope.split(separator: " ").map(String.init) }
        root["claudeAiOauth"] = o
        let saved = Keychain.write(item, root)
            && Keychain.read(item).flatMap({ OAuthCreds($0) })?.accessToken == fresh.accessToken
        return .ok(fresh, saved: saved)
    }
}

extension Data {
    init?(hex: String) {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        self = data
    }
}
