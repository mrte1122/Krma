import AppKit
import Foundation
import Network

/// Refresh coordinator + model: interval timer, wake-from-sleep refresh with debounce, refresh
/// when the network comes back, favorites, history, the shell cache file and demo data.
@MainActor
final class KarmaStore: ObservableObject {
    @Published private(set) var account: Account?
    @Published private(set) var current: KarmaSnapshot?
    /// Every subreddit with karma, highest first.
    @Published private(set) var subredditKarma: [SubredditKarma] = []
    @Published private(set) var subscriptions: [SubredditInfo] = []
    @Published private(set) var favorites: [String] = UserDefaults.standard.stringArray(forKey: SettingsKey.favorites) ?? []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var consecutiveFailures = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var now = Date()
    /// Not signed in (or Reddit revoked the sign-in): the popover shows the sign-in card.
    @Published private(set) var needsSignIn = false
    @Published private(set) var rateLimit: RateLimit?

    let history: History
    let notifier = Notifier()
    let vault = TokenVault()
    /// Set by the app so a revoked token resets the sign-in UI.
    var onRevoked: (() -> Void)?

    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var scheduledInterval: TimeInterval = 0
    private var lastRefreshStart = Date.distantPast
    private var lastSubscriptionFetch = Date.distantPast
    private var fetchedThisRun = false
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false
    private static let triggerDebounce: TimeInterval = 30
    private static let subscriptionInterval: TimeInterval = 1800
    static let minInterval: TimeInterval = 60
    static let maxInterval: TimeInterval = 1800

    init(history: History = History(url: Demo.isActive ? nil : History.defaultURL)) {
        self.history = history
    }

    var hasData: Bool { current != nil }

    // MARK: Lifecycle

    func start() {
        if Demo.isActive {
            loadDemo()
            clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            }
            return
        }
        rescheduleIfNeeded()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task { @MainActor in self?.triggeredRefresh() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleIfNeeded() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied {
                    if self.networkWasDown { self.networkWasDown = false; self.triggeredRefresh() }
                } else {
                    self.networkWasDown = true
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Krma.network"))
        Task { await refresh() }
    }

    private func rescheduleIfNeeded() {
        let raw = UserDefaults.standard.double(forKey: SettingsKey.refreshInterval)
        let interval = min(Self.maxInterval, max(Self.minInterval, raw))
        guard interval != scheduledInterval else { return }
        scheduledInterval = interval
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        refreshTimer?.tolerance = interval * 0.1
    }

    private func triggeredRefresh() {
        guard Date().timeIntervalSince(lastRefreshStart) > Self.triggerDebounce else { return }
        Task { await refresh() }
    }

    // MARK: Refresh

    func refresh(notify: Bool = true, force: Bool = false) async {
        guard !isRefreshing else { return }
        if Demo.isActive {
            isRefreshing = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            loadDemo()
            isRefreshing = false
            return
        }
        isRefreshing = true
        lastRefreshStart = Date()
        defer { isRefreshing = false; now = Date() }

        guard !RedditAuth.clientID.isEmpty, vault.isSignedIn else {
            needsSignIn = true
            lastError = nil
            return
        }
        needsSignIn = false

        let client = RedditClient(vault: vault, userHint: account?.name,
                                  onRateLimit: { [weak self] rl in Task { @MainActor in self?.rateLimit = rl } })

        do {
            async let meTask = client.fetchMe()
            async let karmaTask = client.fetchKarmaBreakdown()
            let (me, breakdown) = try await (meTask, karmaTask)

            let snapshot = KarmaSnapshot(
                date: Date(), total: me.total, post: me.post, comment: me.comment, awardee: me.awardee, awarder: me.awarder,
                subreddits: Dictionary(breakdown.map { ($0.name, $0.karma) }, uniquingKeysWith: { a, _ in a }))
            let previous = current ?? history.last
            history.record(snapshot)
            account = Account(name: me.name, iconURL: me.iconURL, created: me.created, inboxCount: me.inboxCount)
            current = snapshot
            subredditKarma = breakdown.sorted { $0.karma.total != $1.karma.total ? $0.karma.total > $1.karma.total : $0.name.lowercased() < $1.name.lowercased() }

            if force || Date().timeIntervalSince(lastSubscriptionFetch) >= Self.subscriptionInterval {
                if let subs = try? await client.fetchSubscriptions() {
                    subscriptions = subs.sorted { $0.name.lowercased() < $1.name.lowercased() }
                    lastSubscriptionFetch = Date()
                }
            }

            lastUpdated = Date()
            lastError = nil
            consecutiveFailures = 0
            if notify {
                notifier.evaluate(previous: previous, current: snapshot, favorites: favorites, jumpsArmed: fetchedThisRun)
            }
            fetchedThisRun = true
            writeCacheFile()
        } catch let e as AuthError where e == .revoked || e == .signedOut || e == .noClientID {
            needsSignIn = true
            lastError = e == .revoked ? e.localizedDescription : nil
            onRevoked?()
        } catch RedditError.unauthorized {
            needsSignIn = true
            lastError = AuthError.revoked.localizedDescription
            onRevoked?()
        } catch {
            consecutiveFailures += 1
            lastError = error.localizedDescription
        }
    }

    // MARK: Favorites

    func isFavorite(_ name: String) -> Bool {
        favorites.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleFavorite(_ name: String) {
        if isFavorite(name) {
            setFavorites(favorites.filter { $0.caseInsensitiveCompare(name) != .orderedSame })
        } else {
            setFavorites(favorites + [canonicalName(name)])
        }
    }

    func setFavorites(_ list: [String]) {
        var seen = Set<String>()
        favorites = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        if !Demo.isActive { UserDefaults.standard.set(favorites, forKey: SettingsKey.favorites) }
        writeCacheFile()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        var list = favorites
        list.move(fromOffsets: source, toOffset: destination)
        setFavorites(list)
    }

    /// The spelling Reddit uses, when the subreddit is known; otherwise what was typed (minus "r/").
    func canonicalName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.lowercased().hasPrefix("r/") { n = String(n.dropFirst(2)) }
        if n.hasPrefix("/") { n = String(n.dropFirst()) }
        if let k = subredditKarma.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return k.name }
        if let s = subscriptions.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return s.name }
        return n
    }

    // MARK: Derived values

    func karma(in subreddit: String) -> SubKarma? { current?.karma(in: subreddit) }

    func delta(_ period: Period) -> Delta? {
        guard let c = current else { return nil }
        return history.delta(period: period, now: now, current: c)
    }

    func subredditDelta(_ name: String, _ period: Period) -> Int? {
        delta(period).map { $0.subreddits[name.lowercased()] ?? 0 }
    }

    func series(_ period: Period, subreddit: String? = nil) -> [(date: Date, value: Int)] {
        history.series(period: period, now: now, current: current, subreddit: subreddit)
    }

    /// Karma list plus subscriptions you have no karma in yet, highest karma first.
    var allSubreddits: [SubredditKarma] {
        var seen = Set(subredditKarma.map { $0.name.lowercased() })
        var out = subredditKarma
        for s in subscriptions where seen.insert(s.name.lowercased()).inserted {
            out.append(SubredditKarma(name: s.name, karma: .zero))
        }
        return out
    }

    var favoriteRows: [SubredditKarma] {
        favorites.map { SubredditKarma(name: canonicalName($0), karma: karma(in: $0) ?? .zero) }
    }

    func subscriberCount(_ name: String) -> Int? {
        subscriptions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.subscribers
    }

    // MARK: Shell cache

    /// `~/Library/Application Support/Krma/karma.json`, for shell prompts and scripts.
    private func writeCacheFile() {
        guard !Demo.isActive, let c = current, let a = account else { return }
        let period = Period.current
        let d = delta(period)
        var dict: [String: Any] = [
            "user": a.name,
            "updatedAt": ISO8601DateFormatter().string(from: c.date),
            "total": c.total, "post": c.post, "comment": c.comment, "awardee": c.awardee, "awarder": c.awarder,
            "period": period.rawValue,
            "change": d?.total ?? 0,
            "favorites": favoriteRows.map { row -> [String: Any] in
                ["name": row.name, "post": row.karma.post, "comment": row.karma.comment, "total": row.karma.total,
                 "change": d?.subreddits[row.name.lowercased()] ?? 0]
            },
        ]
        if let since = d?.since { dict["changeSince"] = ISO8601DateFormatter().string(from: since) }
        let url = History.directory.appendingPathComponent("karma.json")
        try? FileManager.default.createDirectory(at: History.directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        var lines: [String] = []
        lines.append("Krma \(RedditAuth.appVersion) · \(SystemInfo.macOS), \(SystemInfo.chip)")
        let id = RedditAuth.clientID
        lines.append("client id: " + (id.isEmpty ? "none" : "\(id.prefix(4))…, \(id.count) chars (\(UserDefaults.standard.string(forKey: SettingsKey.redditClientID)?.isEmpty == false ? "custom" : "built in"))"))
        lines.append("signed in: \(vault.isSignedIn)")
        if let a = account { lines.append("user: u/\(a.name)") }
        if let c = current {
            lines.append("karma: total \(c.total) · post \(c.post) · comment \(c.comment) · awardee \(c.awardee) · awarder \(c.awarder)")
            lines.append("subreddits with karma: \(c.subreddits.count) · subscriptions loaded: \(subscriptions.count)")
        }
        lines.append("favorites: " + (favorites.isEmpty ? "none" : favorites.joined(separator: ", ")))
        if let f = history.first, let l = history.last {
            lines.append("history: \(history.snapshots.count) snapshots, \(f.date.formatted(date: .abbreviated, time: .shortened)) → \(l.date.formatted(date: .abbreviated, time: .shortened))")
        } else {
            lines.append("history: empty")
        }
        for p in Period.allCases {
            if let d = delta(p) { lines.append("change \(p.rawValue): \(KarmaMath.signed(d.total)) since \(d.since.formatted(date: .abbreviated, time: .shortened))\(d.truncated ? " (history shorter than period)" : "")") }
        }
        if let r = rateLimit { lines.append("rate limit: \(r.used) used, \(r.remaining) left, resets \(KarmaMath.relative(r.resetAt, now: now).replacingOccurrences(of: " ago", with: ""))") }
        if let u = lastUpdated { lines.append("updated: \(u.formatted(date: .abbreviated, time: .standard))") }
        if let e = lastError { lines.append("last error: \(e) (\(consecutiveFailures) in a row)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Demo and previews

    func previewSignedOut() {
        account = nil
        current = nil
        subredditKarma = []
        needsSignIn = true
    }

    /// Sample account with 30 days of history; the README screenshots use this.
    func loadDemo() {
        let subs: [(String, Int, Int)] = [
            ("swift", 3_210, 1_140), ("macapps", 980, 2_210), ("apple", 640, 1_320), ("programming", 1_100, 430),
            ("MechanicalKeyboards", 430, 120), ("cats", 1_500, 260), ("iOSProgramming", 210, 380),
            ("unpopularopinion", 12, -4), ("homelab", 96, 155),
        ]
        var map: [String: SubKarma] = [:]
        for (n, p, c) in subs { map[n] = SubKarma(post: p, comment: c) }
        let endDate = Date()
        let final = KarmaSnapshot(date: endDate, total: 12_431, post: 7_860, comment: 4_402, awardee: 120, awarder: 49, subreddits: map)

        // Deterministic random walk backwards from the final values: today +37, week +212, month +905.
        var rng = UInt64(0x9E3779B97F4A7C15)
        func next() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        var hist: [KarmaSnapshot] = []
        var total = final.total, post = final.post, comment = final.comment
        var s = map
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: endDate)
        let points = 30 * 4
        var landed = false
        for i in 0..<points {
            let date = endDate.addingTimeInterval(-Double(i) * 6 * 3600)
            if i == 0 { hist.append(final); continue }
            if date < todayStart && !landed {
                landed = true
                // Land exactly on 12,394 at the start of today so the "today" chip reads +37.
                total = 12_394; post -= 20; comment -= 17
                s["swift"] = SubKarma(post: 3_190, comment: 1_125); s["macapps"] = SubKarma(post: 980, comment: 2_205)
            } else {
                let step = Int(next() * 22) - 3
                total = max(0, total - step)
                if next() < 0.6 { post = max(0, post - step) } else { comment = max(0, comment - step) }
                let keys = Array(s.keys)
                let k = keys[Int(next() * Double(keys.count)) % keys.count]
                var v = s[k]!
                if next() < 0.5 { v.post = max(0, v.post - step) } else { v.comment = v.comment - step }
                s[k] = v
            }
            hist.append(KarmaSnapshot(date: date, total: total, post: post, comment: comment, awardee: 120, awarder: 49, subreddits: s))
        }
        history.replaceAll(hist)
        account = Account(name: "demo_cat", iconURL: nil, created: endDate.addingTimeInterval(-6.3 * 365 * 86_400), inboxCount: 2)
        current = final
        subredditKarma = subs.map { SubredditKarma(name: $0.0, karma: SubKarma(post: $0.1, comment: $0.2)) }
            .sorted { $0.karma.total > $1.karma.total }
        subscriptions = ["swift", "macapps", "apple", "programming", "MechanicalKeyboards", "cats", "iOSProgramming", "homelab",
                         "Terraria", "espresso", "SwiftUI"].map { SubredditInfo(name: $0, subscribers: nil, iconURL: nil) }
        if favorites.isEmpty { favorites = ["swift", "macapps", "apple"] }
        rateLimit = RateLimit(used: 4, remaining: 96, resetAt: endDate.addingTimeInterval(420))
        lastUpdated = endDate
        lastError = nil
        needsSignIn = false
        now = endDate
    }
}

enum SystemInfo {
    /// e.g. "macOS 26.1"
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                  : "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    static var chip: String {
        #if arch(arm64)
        return "Apple silicon"
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return rosetta ? "Apple silicon (Rosetta)" : "Intel"
        #endif
    }
}
