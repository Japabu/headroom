import AppKit
import Combine

/// One Claude account Headroom has seen, whether or not Claude Code is logged in to it right now.
struct AccountState: Identifiable {
    var id: String
    var email: String?
    var org: String?
    var plan: String?
    var usage: Usage?
    var issue: AccountIssue?
    /// Its saved login stopped working; only last known numbers are left.
    var signedOut = false
    var label = ""

    /// The Claude Code slot that holds this login right now, if any.
    var slot: String?
    var lastActivity: Date?
    var runningSessions = 0
    var nextFetch = Date.distantPast
    var failures = 0
    var fetching = false
}

struct ResetRow: Identifiable {
    var date: Date
    var account: String
    var what: String
    var id: String { "\(account)|\(date.timeIntervalSince1970)" }
}

/// A Claude Code login slot and the account it was holding when last read.
private struct SlotState {
    var slot: LoginSlot
    var activity = Discovery.Activity(last: nil, running: 0)
    var identity: Identity?
    var fingerprint: String?
    var issue: AccountIssue?
    var nextFetch = Date.distantPast
    var failures = 0
    var fetching = false
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
    private var records: [String: AccountState] = [:]
    private var slots: [String: SlotState] = [:]
    private var timer: Timer?
    private var lastDiscovery = Date.distantPast
    private var discovering = false
    private var handledResets = Set<String>()
    private var bag = Set<AnyCancellable>()
    private var quiet = false

    var isRefreshing: Bool { slots.values.contains { $0.fetching } || records.values.contains { $0.fetching } }
    var inUse: AccountState? { accounts.first { $0.id == inUseID } }

    init() {
        for (key, c) in Cache.load() {
            records[key] = AccountState(id: key, email: c.email, org: c.org, plan: c.plan, usage: c.usage, signedOut: c.signedOut ?? false)
        }
        publish()
    }

    /// `quiet` is for snapshots: no notifications, no renewals, no saved logins.
    func start(quiet: Bool = false) {
        self.quiet = quiet
        if quiet {
            notifier.enabled = false
        } else {
            notifier.onOpen = { [weak self] in self?.onOpenRequest?() }
            notifier.setup()
        }
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.publish() } }
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
        if let key = inUseID, now.timeIntervalSince(records[key]?.usage?.fetchedAt ?? .distantPast) > 60 {
            fetchSoon(key, at: now)
        }
        fetchDue()
    }

    func refreshAll() {
        for key in slots.keys { slots[key]?.nextFetch = .distantPast }
        for key in records.keys { records[key]?.nextFetch = .distantPast }
        lastDiscovery = .distantPast
        tick()
    }

    // MARK: Slots and accounts

    private func discover() {
        discovering = true
        lastDiscovery = Date()
        let extra = UserDefaults.standard.stringArray(forKey: "extraConfigDirs") ?? []
        Task.detached(priority: .utility) {
            let found = Discovery.slots(extraDirs: extra).map { Discovery.Found(slot: $0, activity: Discovery.activity($0.configDir)) }
            await MainActor.run { self.apply(found) }
        }
    }

    private func apply(_ found: [Discovery.Found]) {
        discovering = false
        discovered = true
        var next: [String: SlotState] = [:]
        for f in found {
            var s = slots[f.slot.id] ?? SlotState(slot: f.slot)
            s.slot = f.slot
            s.activity = f.activity
            next[f.slot.id] = s
        }
        slots = next
        remap()
        fetchDue()
    }

    /// Ties each account to the slot holding it now, and picks the account in use:
    /// the one in the slot Claude Code was active in most recently.
    private func remap() {
        for key in records.keys {
            records[key]?.slot = nil
            records[key]?.lastActivity = nil
            records[key]?.runningSessions = 0
        }
        var best: (key: String, last: Date)?
        for (service, s) in slots {
            guard let key = s.identity?.key, records[key] != nil else { continue }
            records[key]?.slot = service
            records[key]?.runningSessions += s.activity.running
            let last = s.activity.last ?? .distantPast
            if last > (records[key]?.lastActivity ?? .distantPast) { records[key]?.lastActivity = last }
            if best == nil || last > best!.last { best = (key, last) }
        }
        inUseID = best?.key
        publish()
    }

    private func publish() {
        var list = Array(records.values)
        for i in list.indices {
            let custom = settings.labels[list[i].id].flatMap { $0.isEmpty ? nil : $0 }
            let name = list[i].email.flatMap { $0.split(separator: "@").first.map(String.init) }
            list[i].label = custom ?? name ?? "Claude account"
        }
        let inUse = inUseID
        func rank(_ a: AccountState) -> Int { a.id == inUse ? 0 : (a.slot != nil ? 1 : 2) }
        list.sort { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        accounts = list
        publishIcon()
    }

    private func save() {
        Cache.save(records.mapValues {
            CachedAccount(usage: $0.usage, email: $0.email, plan: $0.plan, org: $0.org, signedOut: $0.signedOut)
        })
    }

    // MARK: Fetching

    private func fetchDue() {
        let t = Date()
        for (service, s) in slots where !s.fetching && s.nextFetch <= t { fetchSlot(service) }

        // Saved copies are used only while every slot is known to hold some other account.
        // That way Headroom never renews a login that Claude Code is still using.
        let settled = slots.values.allSatisfy { !$0.fetching && ($0.identity != nil || $0.issue == .notLoggedIn) }
        guard settled else { return }
        for (key, r) in records where r.slot == nil && !r.signedOut && !r.fetching && r.nextFetch <= t { fetchCopy(key) }
    }

    private func fetchSlot(_ service: String) {
        guard let s = slots[service] else { return }
        slots[service]?.fetching = true
        publish()
        let known = s.identity.flatMap { id in s.fingerprint.map { (fingerprint: $0, identity: id) } }
        let renew = settings.renewLogins && !quiet
        let keep = !quiet
        Task {
            let o = await Fetcher.run(.slot(s.slot, claudeRunning: s.activity.running > 0), known: known,
                                      renewAllowed: renew, keepCopy: keep)
            self.finishSlot(service, o)
        }
    }

    private func finishSlot(_ service: String, _ o: Fetcher.Outcome) {
        guard var s = slots[service] else { return }
        s.fetching = false
        s.issue = o.issue
        s.identity = o.identity
        s.fingerprint = o.identity == nil ? nil : o.fingerprint
        s.failures = o.usage == nil ? s.failures + 1 : 0
        if let id = o.identity {
            var r = records[id.key] ?? AccountState(id: id.key)
            r.email = id.email ?? r.email
            r.org = id.org ?? r.org
            r.signedOut = false
            take(o, into: &r)
            records[id.key] = r
        }
        s.nextFetch = Date().addingTimeInterval(delay(o, failures: s.failures, inUse: o.identity?.key == inUseID))
        slots[service] = s
        afterFetch()
    }

    private func fetchCopy(_ key: String) {
        guard let r = records[key] else { return }
        records[key]?.fetching = true
        publish()
        let identity = Identity(key: key, email: r.email, org: r.org)
        let renew = settings.renewLogins && !quiet
        Task {
            let o = await Fetcher.run(.copy(identity), known: nil, renewAllowed: renew)
            self.finishCopy(key, o)
        }
    }

    private func finishCopy(_ key: String, _ o: Fetcher.Outcome) {
        guard var r = records[key] else { return }
        r.fetching = false
        r.failures = o.usage == nil ? r.failures + 1 : 0
        take(o, into: &r)
        if o.issue == .signedOut { r.signedOut = true }
        r.nextFetch = Date().addingTimeInterval(delay(o, failures: r.failures, inUse: false))
        records[key] = r
        afterFetch()
    }

    private func take(_ o: Fetcher.Outcome, into r: inout AccountState) {
        if let p = o.plan { r.plan = p }
        if let u = o.usage {
            r.usage = u
            lastUpdated = u.fetchedAt
        }
        r.issue = o.issue
    }

    private func afterFetch() {
        remap()
        save()
        now = Date()
        checkNotifications()
        fetchDue()
    }

    private func delay(_ o: Fetcher.Outcome, failures: Int, inUse: Bool) -> TimeInterval {
        if let r = o.retryAfter { return max(60, r) }
        if o.usage == nil {
            switch o.issue {
            case .rateLimited: return 300
            case .offline: return min(600, 30 * pow(2, Double(min(failures, 5))))
            case .unreadable: return 900
            case .signedOut: return 6 * 3600
            default: return 120 // expired or missing login: look again soon, Claude Code may have renewed it
            }
        }
        return inUse ? 120 : 600
    }

    private func fetchSoon(_ key: String, at t: Date) {
        if let service = records[key]?.slot, let n = slots[service]?.nextFetch {
            slots[service]?.nextFetch = min(n, t)
        } else if let n = records[key]?.nextFetch {
            records[key]?.nextFetch = min(n, t)
        }
    }

    // MARK: Resets and notifications

    private func noticeResets() {
        let t = Date()
        for a in accounts {
            guard let u = a.usage else { continue }
            for w in u.all {
                guard let r = w.resetsAt, r <= t else { continue }
                guard handledResets.insert("\(a.id)|\(w.id)|\(r.timeIntervalSince1970)").inserted else { continue }
                fetchSoon(a.id, at: t.addingTimeInterval(20))
                guard w.id == "session", t.timeIntervalSince(r) < 3600 else { continue }
                let key = Notifier.windowKey(a.id, r)
                let wasTight = w.percent >= 90 || notifier.hasFired("hot|" + key) || notifier.hasFired("limit|" + key)
                guard wasTight else { continue }
                if settings.notifyRefill {
                    notifier.post(key: "refill|" + key, title: "\(a.label) is refilled", body: "A fresh 5-hour session is ready.")
                }
                if a.id == inUseID { onRefill?() }
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
        let others = accounts.filter { $0.id != inUseID }
        onIconChange?(IconState.make(for: inUse, others: others, now: Date(), mode: settings.textMode, discovered: discovered))
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
