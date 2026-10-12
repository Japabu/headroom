import AppKit
import Combine

struct AccountState: Identifiable {
    var account: Account
    var label = ""
    var email: String?
    var plan: String?
    var usage: Usage?
    var issue: AccountIssue?
    var lastActivity: Date?
    var runningSessions = 0
    var nextFetch = Date.distantPast
    var failures = 0
    var fetching = false

    var id: String { account.id }
}

struct ResetRow: Identifiable {
    var date: Date
    var account: String
    var what: String
    var id: String { "\(account)|\(date.timeIntervalSince1970)" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [AccountState] = []
    @Published private(set) var inUseID: String?
    @Published private(set) var now = Date()
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var discovered = false
    @Published private(set) var openCount = 0
    let settings = Settings()

    var onIconChange: ((IconState) -> Void)?
    var onRefill: (() -> Void)?
    var onOpenRequest: (() -> Void)?

    private let notifier = Notifier()
    private var cache = Cache.load()
    private var timer: Timer?
    private var lastDiscovery = Date.distantPast
    private var discovering = false
    private var handledResets = Set<String>()
    private var bag = Set<AnyCancellable>()
    private var allowRenew = true

    var isRefreshing: Bool { accounts.contains { $0.fetching } }
    var inUse: AccountState? { accounts.first { $0.id == inUseID } }

    /// `quiet` is for snapshots: no notifications, no login renewals.
    func start(quiet: Bool = false) {
        if quiet {
            notifier.enabled = false
            allowRenew = false
        } else {
            notifier.onOpen = { [weak self] in self?.onOpenRequest?() }
            notifier.setup()
        }
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.settingsChanged() } }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func tick() {
        now = Date()
        if !discovering && now.timeIntervalSince(lastDiscovery) >= 60 { discover() }
        noticeResets()
        fetchDue()
        checkNotifications()
        publishIcon()
    }

    func popoverWillOpen() {
        openCount += 1
        now = Date()
        if let i = accounts.firstIndex(where: { $0.id == inUseID }),
           now.timeIntervalSince(accounts[i].usage?.fetchedAt ?? .distantPast) > 60 {
            accounts[i].nextFetch = .distantPast
        }
        fetchDue()
    }

    func refreshAll() {
        for i in accounts.indices { accounts[i].nextFetch = .distantPast }
        lastDiscovery = .distantPast
        tick()
    }

    // MARK: Discovery

    private func discover() {
        discovering = true
        lastDiscovery = Date()
        let extra = UserDefaults.standard.stringArray(forKey: "extraConfigDirs") ?? []
        let known = Set(accounts.filter { $0.email != nil }.map(\.id))
        Task.detached(priority: .utility) {
            let found = Discovery.accounts(extraDirs: extra).map { a in
                Discovery.Found(account: a, activity: Discovery.activity(a.configDir),
                                email: known.contains(a.id) ? nil : Discovery.email(a.globalConfig))
            }
            await MainActor.run { self.apply(found) }
        }
    }

    private func apply(_ found: [Discovery.Found]) {
        discovering = false
        discovered = true
        var next: [AccountState] = []
        for f in found {
            var s = accounts.first { $0.id == f.account.id } ?? newState(f.account)
            s.account = f.account
            if let e = f.email { s.email = e }
            s.lastActivity = f.activity.last
            s.runningSessions = f.activity.running
            next.append(s)
        }
        let previous = inUseID
        inUseID = next.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }?.id
        if inUseID != previous, let i = next.firstIndex(where: { $0.id == inUseID }) {
            next[i].nextFetch = min(next[i].nextFetch, Date())
        }
        accounts = next
        applyLabels()
        fetchDue()
        publishIcon()
    }

    private func newState(_ account: Account) -> AccountState {
        var s = AccountState(account: account)
        if let c = cache[account.id] {
            s.usage = c.usage
            s.email = c.email
            s.plan = c.plan
        }
        return s
    }

    private func applyLabels() {
        for i in accounts.indices {
            let s = accounts[i]
            let custom = settings.labels[s.id].flatMap { $0.isEmpty ? nil : $0 }
            accounts[i].label = custom ?? Discovery.defaultLabel(s.account, email: s.email)
        }
        let inUse = inUseID
        accounts.sort { a, b in
            let ka = a.id == inUse ? 0 : 1, kb = b.id == inUse ? 0 : 1
            if ka != kb { return ka < kb }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    private func settingsChanged() {
        applyLabels()
        publishIcon()
    }

    // MARK: Fetching

    private func fetchDue() {
        let t = Date()
        for s in accounts where !s.fetching && s.nextFetch <= t { fetch(s.id) }
    }

    private func fetch(_ id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].fetching = true
        let s = accounts[i]
        let renew = settings.renewLogins && allowRenew
        Task {
            let outcome = await Fetcher.run(item: s.account.item, claudeRunning: s.runningSessions > 0,
                                            renewAllowed: renew, wantEmail: s.email == nil)
            self.finish(id, outcome)
        }
    }

    private func finish(_ id: String, _ o: Fetcher.Outcome) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        var s = accounts[i]
        s.fetching = false
        if let p = o.plan { s.plan = p }
        if let e = o.email { s.email = e }
        if let u = o.usage {
            s.usage = u
            s.failures = 0
            lastUpdated = u.fetchedAt
        } else {
            s.failures += 1
        }
        s.issue = o.issue
        s.nextFetch = Date().addingTimeInterval(delay(for: s, o))
        accounts[i] = s
        cache[id] = CachedAccount(usage: s.usage, email: s.email, plan: s.plan)
        Cache.save(cache)
        applyLabels()
        now = Date()
        checkNotifications()
        publishIcon()
    }

    private func delay(for s: AccountState, _ o: Fetcher.Outcome) -> TimeInterval {
        if let r = o.retryAfter { return max(60, r) }
        if o.usage == nil {
            switch o.issue {
            case .rateLimited: return 300
            case .offline: return min(600, 30 * pow(2, Double(min(s.failures, 5))))
            case .unreadable: return 900
            default: return 120 // expired or missing login: look again soon, Claude Code may have renewed it
            }
        }
        return s.id == inUseID ? 120 : 600
    }

    // MARK: Resets and notifications

    private func noticeResets() {
        let t = Date()
        for i in accounts.indices {
            guard let u = accounts[i].usage else { continue }
            for w in u.all {
                guard let r = w.resetsAt, r <= t else { continue }
                guard handledResets.insert("\(accounts[i].id)|\(w.id)|\(r.timeIntervalSince1970)").inserted else { continue }
                accounts[i].nextFetch = min(accounts[i].nextFetch, t.addingTimeInterval(20))
                guard w.id == "session", t.timeIntervalSince(r) < 3600 else { continue }
                let key = Notifier.windowKey(accounts[i].id, r)
                let wasTight = w.percent >= 90 || notifier.hasFired("hot|" + key) || notifier.hasFired("limit|" + key)
                guard wasTight else { continue }
                if settings.notifyRefill {
                    notifier.post(key: "refill|" + key, title: "\(accounts[i].label) is refilled", body: "A fresh 5-hour session is ready.")
                }
                if accounts[i].id == inUseID { onRefill?() }
            }
        }
    }

    private func checkNotifications() {
        let t = Date()
        for s in accounts {
            guard let u = s.usage?.at(t) else { continue }
            if let w = u.session, let r = w.resetsAt {
                let key = Notifier.windowKey(s.id, r)
                if w.isLimited {
                    if settings.notifyLimit {
                        var body = "Back at \(Fmt.when(r, now: t))."
                        if let alt = bestAlternative(excluding: s.id, at: t) {
                            body += " \(alt.label) has \(Int(alt.left.rounded()))% of its session left."
                        }
                        notifier.post(key: "limit|" + key, title: "\(s.label) hit its session limit", body: body)
                    }
                } else if w.isHot(t), settings.notifyHot {
                    var body = "\(Int(w.percent.rounded()))% of the session used."
                    if let out = w.runsOut(t) { body += " At this pace you run out around \(Fmt.when(out, now: t))." }
                    body += " It resets at \(Fmt.when(r, now: t))."
                    notifier.post(key: "hot|" + key, title: "\(s.label) is running hot", body: body)
                }
            }
            if let w = u.week, let r = w.resetsAt {
                let key = Notifier.windowKey(s.id, r)
                if w.isLimited {
                    if settings.notifyLimit {
                        notifier.post(key: "wlimit|" + key, title: "\(s.label) hit its weekly limit", body: "Back \(Fmt.when(r, now: t)).")
                    }
                } else if settings.notifyUseIt, w.left >= 40, r.timeIntervalSince(t) <= 6 * 3600 {
                    notifier.post(key: "useit|" + key, title: "Use it or lose it",
                                  body: "\(s.label)’s week resets in \(Fmt.duration(r.timeIntervalSince(t))) with \(Int(w.left.rounded()))% unused.")
                }
            }
        }
    }

    private func bestAlternative(excluding id: String, at t: Date) -> (label: String, left: Double)? {
        accounts.compactMap { o -> (label: String, left: Double)? in
            guard o.id != id, let u = o.usage?.at(t), u.week?.isLimited != true else { return nil }
            return (o.label, u.session?.left ?? 100)
        }.max { $0.left < $1.left }
    }

    private func publishIcon() {
        let t = Date()
        let others = accounts.filter { $0.id != inUseID }
        onIconChange?(IconState.make(for: inUse, others: others, now: t, mode: settings.textMode, discovered: discovered))
    }

    // MARK: For the menu

    func nextResets() -> [ResetRow] {
        let t = now
        var rows: [ResetRow] = []
        for s in accounts {
            guard let u = s.usage?.at(t) else { continue }
            for w in u.all {
                guard let r = w.resetsAt, r > t else { continue }
                let what = w.id == "session" ? "session" : (w.id == "week" ? "week" : w.label)
                if let j = rows.firstIndex(where: { $0.account == s.label && abs($0.date.timeIntervalSince(r)) < 300 }) {
                    rows[j].what += " + " + what
                } else {
                    rows.append(ResetRow(date: r, account: s.label, what: what))
                }
            }
        }
        return Array(rows.sorted { $0.date < $1.date }.prefix(6))
    }
}
