import Charts
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: KarmaStore
    @ObservedObject var signIn: RedditSignIn
    var openSettings: () -> Void

    @AppStorage(SettingsKey.period) private var periodRaw = Period.today.rawValue
    @AppStorage(SettingsKey.exactNumbers) private var exact = false
    @AppStorage(SettingsKey.showAllSubreddits) private var showAll = false
    @State private var diagnosticsCopied = false

    private var period: Period { Period(rawValue: periodRaw) ?? .today }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banner
            if store.needsSignIn {
                SignInCard(signIn: signIn)
            } else {
                Picker("Period", selection: $periodRaw) {
                    ForEach(Period.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let c = store.current {
                    TotalCard(snapshot: c, delta: store.delta(period), series: store.series(period), period: period, now: store.now)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Loading your karma…").font(.callout).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(14).card()
                }
                favoritesSection
                AllSubredditsSection(store: store, period: period, expanded: $showAll)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Avatar(url: store.account?.iconURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.account.map { "u/\($0.name)" } ?? "Krma").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(store.isRefreshing)
        }
    }

    private var subtitle: String {
        if store.needsSignIn { return "Not connected" }
        var parts: [String] = []
        if let u = store.lastUpdated { parts.append("updated \(KarmaMath.relative(u, now: store.now))") }
        if let a = store.account, let created = a.created {
            let years = store.now.timeIntervalSince(created) / (365.25 * 86_400)
            parts.append(years >= 1 ? String(format: "%.0f yr on Reddit", years.rounded(.down)) : "new account")
        }
        return parts.isEmpty ? "Reddit karma" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var banner: some View {
        if let err = store.lastError {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if store.consecutiveFailures > 1 {
                        Text("Refresh failed \(store.consecutiveFailures) times").font(.caption.bold())
                    }
                    Text(err).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FAVORITES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if store.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("No favorites yet", systemImage: "star").font(.callout.weight(.medium))
                    Text("Star a subreddit below to track its local karma here and in the menu bar.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                ForEach(store.favoriteRows) { row in
                    FavoriteRow(row: row, change: store.subredditDelta(row.name, period), period: period, exact: exact) {
                        store.toggleFavorite(row.name)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
            Spacer()
            if let a = store.account {
                Link("Profile", destination: Links.user(a.name))
                Spacer()
            }
            Button(diagnosticsCopied ? "Copied" : "Diagnostics") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.diagnosticsText(), forType: .string)
                diagnosticsCopied = true
            }
            .help("Copy diagnostics (never includes your tokens)")
            Spacer()
            Link(destination: Links.tip) { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                .help("Enjoying Krma? Buy me a coffee on Ko-fi")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - Pieces

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color(ns: Theme.accent).opacity(0.15))
            Image(systemName: "arrowshape.up.fill").font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Color(ns: Theme.accent))
        }
    }
}

/// "▲ 37" in green, "▼ 3" in red, "no change" in grey.
struct ChangeChip: View {
    let value: Int?
    var caption: String? = nil
    var compact = false

    private var color: Color { Color(ns: Theme.readable(Theme.change(value ?? 0))) }

    var body: some View {
        let text: String = {
            guard let v = value else { return "—" }
            if v == 0 { return compact ? "0" : "no change" }
            return (v > 0 ? "▲ " : "▼ ") + KarmaMath.exact(abs(v))
        }()
        HStack(spacing: 3) {
            Text(text)
            if let caption, !compact { Text(caption).foregroundStyle(.secondary) }
        }
        .font((compact ? Font.caption2 : .caption).weight(.semibold).monospacedDigit())
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 1 : 3)
        .background((value ?? 0) == 0 ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(color.opacity(0.14)),
                    in: Capsule())
    }
}

struct TotalCard: View {
    let snapshot: KarmaSnapshot
    let delta: Delta?
    let series: [(date: Date, value: Int)]
    let period: Period
    let now: Date

    private var awards: Int { snapshot.awardee + snapshot.awarder }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(KarmaMath.exact(snapshot.total))
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                Text("karma").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ChangeChip(value: delta?.total, caption: period.label)
            }
            Sparkline(points: series, tint: Color(ns: Theme.change(delta?.total ?? 0)), accent: Color(ns: Theme.accent))
                .frame(height: 52)
            SplitBar(parts: [(Double(max(0, snapshot.post)), Color(ns: Theme.accent)),
                             (Double(max(0, snapshot.comment)), Color(ns: .systemBlue)),
                             (Double(max(0, awards)), Color(ns: .systemYellow))])
            // One row when it fits; otherwise awards drop to a second line rather than truncating.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    legend("Post", snapshot.post, delta?.post, Color(ns: Theme.accent))
                    legend("Comment", snapshot.comment, delta?.comment, Color(ns: .systemBlue))
                    legend("Awards", awards, nil, Color(ns: .systemYellow))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        legend("Post", snapshot.post, delta?.post, Color(ns: Theme.accent))
                        legend("Comment", snapshot.comment, delta?.comment, Color(ns: .systemBlue))
                    }
                    legend("Awards", awards, nil, Color(ns: .systemYellow))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let d = delta, d.truncated {
                Text("Since \(d.since.formatted(date: .abbreviated, time: .shortened)), when Krma started keeping history.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if series.count < 2 {
                Text("Collecting history. Changes and the chart appear once your karma moves.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .card()
    }

    private func legend(_ title: String, _ value: Int, _ change: Int?, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
            Text(KarmaMath.exact(value)).monospacedDigit().foregroundStyle(.primary)
            if let c = change, c != 0 {
                Text(KarmaMath.signed(c)).monospacedDigit().foregroundStyle(Color(ns: Theme.readable(Theme.change(c))))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// One capsule split by post / comment / award share.
struct SplitBar: View {
    let parts: [(value: Double, color: Color)]

    var body: some View {
        GeometryReader { geo in
            let sum = max(1, parts.reduce(0) { $0 + $1.value })
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.value > 0 {
                        Capsule().fill(p.color).frame(width: max(4, (geo.size.width - 4) * p.value / sum))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}

struct Sparkline: View {
    let points: [(date: Date, value: Int)]
    let tint: Color
    let accent: Color

    private struct P: Identifiable { let id: Int; let date: Date; let value: Int }

    var body: some View {
        let ps = points.enumerated().map { P(id: $0.offset, date: $0.element.date, value: $0.element.value) }
        let lo = ps.map(\.value).min() ?? 0
        let hi = ps.map(\.value).max() ?? 0
        let pad = max(1, (hi - lo) / 8)
        let line = points.count >= 2 && points.first!.value != points.last!.value ? tint : accent
        if ps.count >= 2 {
            Chart(ps) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Floor", lo - pad), yEnd: .value("Karma", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [line.opacity(0.28), line.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.date), y: .value("Karma", p.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(line)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartLegend(.hidden)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4))
                Text("Chart appears after the first change").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct FavoriteRow: View {
    let row: SubredditKarma
    let change: Int?
    let period: Period
    let exact: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
            .buttonStyle(.borderless)
            .help("Remove from favorites")
            VStack(alignment: .leading, spacing: 2) {
                Text("r/\(row.name)").font(.callout.weight(.medium)).lineLimit(1)
                Text("Post \(KarmaMath.exact(row.karma.post)) · Comment \(KarmaMath.exact(row.karma.comment))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(KarmaMath.exact(row.karma.total)).font(.callout.monospacedDigit().weight(.semibold))
                ChangeChip(value: change, compact: true).help("Change \(period.label)")
            }
            Link(destination: Links.subreddit(row.name)) {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .help("Open r/\(row.name)")
        }
        .padding(10)
        .card()
    }
}

/// Every subreddit with karma (plus subscriptions without any), filterable, star to favorite.
struct AllSubredditsSection: View {
    @ObservedObject var store: KarmaStore
    let period: Period
    @Binding var expanded: Bool
    @State private var filter = ""
    @State private var limit = 30

    private var rows: [SubredditKarma] {
        let all = store.allSubreddits
        guard !filter.isEmpty else { return all }
        let f = filter.lowercased().replacingOccurrences(of: "r/", with: "")
        return all.filter { $0.name.lowercased().contains(f) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter or add a subreddit", text: $filter).textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                let visible = rows
                if visible.isEmpty, !filter.isEmpty {
                    Button {
                        store.toggleFavorite(filter)
                        filter = ""
                    } label: {
                        Label("Add r/\(store.canonicalName(filter)) to favorites", systemImage: "star")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Text("Karma shows once Reddit reports some for it.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visible.prefix(limit)) { row in
                                SubredditLine(row: row, change: store.subredditDelta(row.name, period),
                                              favorite: store.isFavorite(row.name)) { store.toggleFavorite(row.name) }
                            }
                            if visible.count > limit {
                                Button("Show \(min(50, visible.count - limit)) more") { limit += 50 }
                                    .buttonStyle(.borderless).font(.caption).padding(.top, 4)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("All subreddits (\(store.allSubreddits.count))").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

struct SubredditLine: View {
    let row: SubredditKarma
    let change: Int?
    let favorite: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            Text("r/\(row.name)").font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let c = change, c != 0 {
                Text(KarmaMath.signed(c)).font(.caption.monospacedDigit()).foregroundStyle(Color(ns: Theme.readable(Theme.change(c))))
            }
            Text(KarmaMath.exact(row.karma.total)).font(.callout.monospacedDigit())
                .foregroundStyle(row.karma.total == 0 ? .secondary : .primary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }
}

/// First-run / signed-out card: "Sign in with Reddit" via the browser.
struct SignInCard: View {
    @ObservedObject var signIn: RedditSignIn
    /// A draft, committed on Return or Sign in: writing UserDefaults per keystroke made the
    /// field lose focus after one character.
    @State private var clientID = UserDefaults.standard.string(forKey: SettingsKey.redditClientID) ?? ""
    @State private var pasted = ""
    @State private var showPaste = false

    private var trimmedID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveClientIDAndSignIn() {
        UserDefaults.standard.set(trimmedID, forKey: SettingsKey.redditClientID)
        signIn.start()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch signIn.state {
            case .waiting(let url):
                Label("Finish signing in on Reddit", systemImage: "safari").font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Approve Krma in your browser; it sends you straight back here.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Reddit Again") { NSWorkspace.shared.open(url) }
                    Button("Cancel") { signIn.cancel() }
                }
                .controlSize(.small)
                DisclosureGroup("Didn't come back?", isExpanded: $showPaste) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copy the address the browser landed on (it starts with krma://oauth) and paste it here.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            TextField("krma://oauth?state=…&code=…", text: $pasted).onSubmit { signIn.handlePasted(pasted) }
                            Button("Use") { signIn.handlePasted(pasted) }.disabled(pasted.isEmpty)
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            case .exchanging:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Finishing sign-in…").font(.callout) }
            case .idle, .failed:
                if !signIn.hasClientID {
                    setup
                } else {
                    Label("Connect your Reddit account", systemImage: "person.crop.circle.badge.plus")
                        .font(.callout.weight(.semibold))
                    Text("Krma reads your karma totals, the per-subreddit breakdown and your subscriptions (scopes: identity, mysubreddits). It can't post, vote or read messages. Tokens stay in this Mac's Keychain and only go to reddit.com.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = signIn.state {
                        Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Sign in with Reddit") { signIn.start() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .card()
    }

    /// Shown until a client ID exists: Reddit requires every app to be registered.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("One-time setup: a Reddit client ID", systemImage: "key").font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                step(1, "Open reddit.com/prefs/apps. If you already have an app there, edit it, add `krma://oauth` as a redirect URI, and copy its ID.")
                step(2, "Otherwise create one: type **installed app**, redirect URI exactly `krma://oauth`.")
                step(3, "If \"create app\" does nothing, Reddit's Responsible Builder Policy requires approval first. File the developer access request (link below); it's free but reviewed by hand.")
                step(4, "Paste the short ID shown under the app's name here (not the secret; installed apps have none).")
            }
            .font(.caption)
            Link("Reddit's developer access request form", destination: Links.redditAccessRequest).font(.caption)
            HStack {
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if trimmedID.count >= 10 { saveClientIDAndSignIn() } }
                Link("Open Reddit", destination: Links.redditApps).controlSize(.small)
            }
            if !trimmedID.isEmpty, trimmedID.count < 10 {
                Text("That's too short for a Reddit client ID (they're 14–30 characters). Copy the line under the app's name, not the secret or the name.")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = signIn.state {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Button("Sign in with Reddit") { saveClientIDAndSignIn() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(trimmedID.count < 10)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
