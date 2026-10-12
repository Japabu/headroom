import SwiftUI

/// The menu's own view state. It lives in an ObservableObject rather than in @State,
/// because @State is a macro whose compiler plugin ships only with Xcode, and this
/// app builds with the Command Line Tools alone.
final class MenuUIState: ObservableObject {
    @Published var page: MenuView.Page = .main
    @Published var expanded: Set<String> = []
    @Published var hovered: String?
    @Published var accountName = "work"
    @Published var addedToShell = false
    @Published var copied: String?
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var ui: MenuUIState

    enum Page { case main, settings, add }

    var body: some View {
        Group {
            switch ui.page {
            case .main: mainPage
            case .settings: SettingsPage(model: model, settings: settings, ui: ui) { ui.page = .main }
            case .add: AddAccountPage(ui: ui) { ui.page = .main }
            }
        }
        .frame(width: 340)
        .font(.system(size: 13))
        .onChange(of: model.openCount) { ui.page = .main }
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.accounts.isEmpty {
                Divider()
                EmptyState(discovered: model.discovered)
            } else {
                ForEach(model.accounts) { s in
                    Divider()
                    AccountCard(state: s, inUse: s.id == model.inUseID,
                                expanded: s.id == model.inUseID || ui.expanded.contains(s.id), now: model.now) {
                        guard s.id != model.inUseID else { return }
                        if ui.expanded.contains(s.id) { ui.expanded.remove(s.id) } else { ui.expanded.insert(s.id) }
                    }
                }
                let rows = model.nextResets()
                if !rows.isEmpty {
                    Divider()
                    NextResetsView(rows: rows, now: model.now)
                }
            }
            Divider()
            HStack(spacing: 0) {
                FooterButton("Settings…", ui: ui) { ui.page = .settings }
                FooterButton("Add account…", ui: ui) {
                    ui.addedToShell = false
                    ui.copied = nil
                    ui.page = .add
                }
                Spacer()
                FooterButton("Quit", secondary: true, ui: ui) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Headroom").font(.system(size: 13.5, weight: .bold))
            Spacer()
            if let t = model.lastUpdated {
                Text("Updated \(Fmt.time(t))").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if model.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            } else {
                Button { model.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .frame(width: 16, height: 16)
                .help("Refresh now")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

private struct AccountCard: View {
    let state: AccountState
    let inUse: Bool
    let expanded: Bool
    let now: Date
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                SparkView(state: IconState.make(for: state, others: [], now: now, mode: .never), size: 15)
                Text(state.label).fontWeight(.semibold).lineLimit(1)
                if let plan = state.plan { Text(plan).foregroundStyle(.secondary) }
                Spacer(minLength: 6)
                if inUse {
                    Text("In Claude Code")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                } else {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if expanded { full } else { compact }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help(state.email ?? "")
    }

    @ViewBuilder private var full: some View {
        if let email = state.email {
            Text(email).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 22).padding(.top, -5)
        }
        if let issue = state.issue { IssueView(issue: issue, fetchedAt: state.usage?.fetchedAt, now: now) }
        if let u = state.usage?.at(now) {
            ForEach(u.all) { w in WindowRows(window: w, now: now) }
        } else if state.issue == nil {
            Text("Reading usage…").foregroundStyle(.secondary).padding(.leading, 22)
        }
    }

    @ViewBuilder private var compact: some View {
        if let u = state.usage?.at(now) {
            HStack(alignment: .top, spacing: 14) {
                if let s = u.session {
                    MiniMeter(text: s.isLimited ? "Limited · back \(s.resetsAt.map { Fmt.when($0, now: now) } ?? "soon")"
                                                : "Session \(Int(s.percent.rounded()))%" + (s.resetsAt.map { " · " + Fmt.when($0, now: now) } ?? ""),
                              percent: s.percent, tone: s.isLimited ? .crit : (s.isHot(now) ? .warn : .normal))
                }
                if let w = u.week {
                    MiniMeter(text: "Week \(Int(w.percent.rounded()))%" + (w.resetsAt.map { " · " + Fmt.when($0, now: now) } ?? ""),
                              percent: w.percent, tone: w.isLimited ? .crit : (w.isLow ? .warn : .normal))
                }
            }
            .padding(.leading, 22)
            if let issue = state.issue {
                Text(issue.short).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 22)
            }
        } else {
            Text(state.issue?.short ?? "Reading usage…").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 22)
        }
    }
}

private enum Tone {
    case normal, warn, crit
    var color: Color {
        switch self {
        case .normal: .primary
        case .warn: .orange
        case .crit: .red
        }
    }
}

private struct WindowRows: View {
    let window: UsageWindow
    let now: Date

    private struct Line: Hashable { var text: String; var tone: Tone }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Meter(label: window.label, percent: window.percent, pace: window.elapsed(now), tone: tone)
            ForEach(lines, id: \.self) { line in
                Text(line.text)
                    .font(.system(size: 12, weight: line.tone == .normal ? .regular : .semibold))
                    .foregroundStyle(line.tone == .normal ? Color.secondary : line.tone.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 74)
            }
        }
    }

    private var tone: Tone {
        if window.isLimited { return .crit }
        let hot = window.isSessionLength ? window.isHot(now) : window.isLow
        return hot ? .warn : .normal
    }

    private var lines: [Line] {
        guard let r = window.resetsAt else {
            return [Line(text: window.percent == 0 && window.isSessionLength
                         ? "Fresh. The 5-hour clock starts with your next message." : "No reset time reported.", tone: .normal)]
        }
        let until = Fmt.duration(r.timeIntervalSince(now))
        if window.isLimited { return [Line(text: "Limited · back \(Fmt.when(r, now: now)) · in \(until)", tone: .crit)] }
        var out = [Line(text: "Resets \(Fmt.when(r, now: now)) · in \(until)", tone: .normal)]
        if let end = window.runsOut(now) {
            out.append(Line(text: "At this pace you run out around \(Fmt.when(end, now: now))", tone: .warn))
        } else if !window.isSessionLength, window.percent > 0, let p = window.projected(now) {
            out.append(Line(text: "On pace for about \(Int(p.rounded()))% by then", tone: .normal))
        }
        return out
    }
}

private struct Meter: View {
    let label: String
    let percent: Double
    let pace: Double?
    let tone: Tone

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary).lineLimit(1).frame(width: 64, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 6)
                    Capsule().fill(tone.color)
                        .frame(width: percent > 0 ? max(6, w * min(1, percent / 100)) : 0, height: 6)
                    if let pace, pace > 0.01, pace < 0.99 {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary)
                            .frame(width: 2, height: 13)
                            .offset(x: w * pace - 1)
                    }
                }
                .frame(height: 13)
            }
            .frame(height: 13)
            Text("\(Int(percent.rounded()))%").fontWeight(.semibold).monospacedDigit().frame(width: 38, alignment: .trailing)
        }
        .help(pace == nil ? "" : "The tick marks where you'd be at an even pace.")
    }
}

private struct MiniMeter: View {
    let text: String
    let percent: Double
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: tone == .crit ? .semibold : .regular))
                .foregroundStyle(tone == .crit ? Color.red : Color.secondary)
                .lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tone.color).frame(width: percent > 0 ? max(4, g.size.width * min(1, percent / 100)) : 0)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IssueView: View {
    let issue: AccountIssue
    let fetchedAt: Date?
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 22)
    }

    private var text: String {
        guard let f = fetchedAt, now.timeIntervalSince(f) > 300 else { return issue.message }
        return issue.message + " Showing numbers from \(Fmt.when(f, now: now))."
    }
}

private struct NextResetsView: View {
    let rows: [ResetRow]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NEXT RESETS").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.when(row.date, now: now)).fontWeight(.semibold).monospacedDigit()
                        .frame(width: 74, alignment: .leading)
                    Text("in " + Fmt.duration(row.date.timeIntervalSince(now))).font(.system(size: 12)).foregroundStyle(.secondary)
                        .monospacedDigit().frame(width: 74, alignment: .leading)
                    Text("\(row.account) · \(row.what)").lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct EmptyState: View {
    let discovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if discovered {
                Text("No Claude Code login found").fontWeight(.semibold)
                Text("Run claude in a terminal and type /login. Headroom picks it up within a minute.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Looking for Claude logins…").foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

private struct FooterButton: View {
    let title: String
    let secondary: Bool
    @ObservedObject var ui: MenuUIState
    let action: () -> Void

    init(_ title: String, secondary: Bool = false, ui: MenuUIState, action: @escaping () -> Void) {
        self.title = title
        self.secondary = secondary
        self.ui = ui
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(secondary ? .secondary : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(ui.hovered == title ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { ui.hovered = title } else if ui.hovered == title { ui.hovered = nil }
        }
    }
}

private struct PageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 13.5, weight: .bold))
            HStack {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

private struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var ui: MenuUIState
    let back: () -> Void

    private var startAtLogin: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { on in
            LoginItem.set(on)
            ui.objectWillChange.send()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings", back: back)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Text next to the icon")
                    Picker("", selection: $settings.textMode) {
                        ForEach(TextMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Notifications")
                    SwitchRow("Running hot", isOn: $settings.notifyHot)
                    SwitchRow("Limit hit", isOn: $settings.notifyLimit)
                    SwitchRow("Refilled after a limit", isOn: $settings.notifyRefill)
                    SwitchRow("Week ending with lots unused", isOn: $settings.notifyUseIt)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("General")
                    SwitchRow("Renew expired logins", isOn: $settings.renewLogins)
                    Text("Only for accounts with no Claude Code open. The new login is saved where Claude Code keeps it.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SwitchRow("Start at login", isOn: startAtLogin)
                }
                if !model.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Account names")
                        ForEach(model.accounts) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                TextField(Discovery.defaultLabel(s.account, email: s.email), text: labelBinding(s.id))
                                    .textFieldStyle(.roundedBorder)
                                Text(details(s)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func details(_ s: AccountState) -> String {
        [s.email, s.account.configDir.map { ($0.path as NSString).abbreviatingWithTildeInPath }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func labelBinding(_ id: String) -> Binding<String> {
        Binding(get: { settings.labels[id] ?? "" },
                set: { settings.labels[id] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }
}

private struct AddAccountPage: View {
    @ObservedObject var ui: MenuUIState
    let back: () -> Void

    private var slug: String {
        let mapped = String(ui.accountName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "work" : trimmed
    }
    private var command: String { "claude-\(slug)" }
    private var alias: String { "alias \(command)='CLAUDE_CONFIG_DIR=\"$HOME/.claude-\(slug)\" claude'" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Add account", back: back)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Each Claude account gets its own Claude Code folder. Headroom finds it as soon as you log in there.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Name")
                    TextField("work", text: $ui.accountName).textFieldStyle(.roundedBorder)
                        .onChange(of: ui.accountName) { ui.addedToShell = false }
                }
                step(1, "Add a shortcut to your shell:")
                codeBox(alias)
                Button(ui.addedToShell ? "Added to ~/.zshrc" : "Add it to ~/.zshrc for me") {
                    ui.addedToShell = ShellConfig.appendAlias(alias, name: command)
                }
                .disabled(ui.addedToShell)
                step(2, "Open a new terminal tab and run:")
                codeBox(command)
                step(3, "Type /login and sign in with the other account. It shows up here within a minute.")
            }
            .padding(14)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBox(_ code: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(code).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(ui.copied == code ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                ui.copied = code
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
