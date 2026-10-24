import Foundation

/// Local karma history. Reddit only reports the current numbers, so every change is recorded here
/// to compute "today / 7 days / 30 days" deltas and draw the sparkline.
final class History {
    private(set) var snapshots: [KarmaSnapshot] = []
    let url: URL?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Krma", isDirectory: true)
    }
    static var defaultURL: URL { directory.appendingPathComponent("history.json") }

    /// Pass nil for an in-memory history (tests, demo).
    init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        snapshots = ((try? dec.decode([KarmaSnapshot].self, from: data)) ?? []).sorted { $0.date < $1.date }
    }

    var first: KarmaSnapshot? { snapshots.first }
    var last: KarmaSnapshot? { snapshots.last }

    /// Appends when something changed, or when a day has passed since the last entry.
    /// Returns whether an entry was written.
    @discardableResult
    func record(_ s: KarmaSnapshot) -> Bool {
        if let l = snapshots.last, l.sameValues(as: s), s.date.timeIntervalSince(l.date) < 86_400 { return false }
        snapshots.append(s)
        snapshots = KarmaMath.prune(snapshots, now: s.date)
        save()
        return true
    }

    func replaceAll(_ list: [KarmaSnapshot]) {
        snapshots = list.sorted { $0.date < $1.date }
    }

    /// The latest snapshot at or before `date`, else the earliest one (history shorter than asked).
    func baseline(at date: Date) -> KarmaSnapshot? {
        snapshots.last { $0.date <= date } ?? snapshots.first
    }

    func delta(period: Period, now: Date, current: KarmaSnapshot) -> Delta? {
        guard !snapshots.isEmpty else { return nil }
        let start = period.start(now: now)
        guard let base = start.map({ baseline(at: $0) }) ?? snapshots.first else { return nil }
        let truncated = start.map { base.date > $0 } ?? false
        return KarmaMath.delta(from: base, to: current, truncated: truncated)
    }

    /// Points for the sparkline: the baseline, everything inside the period, and the current value.
    func series(period: Period, now: Date, current: KarmaSnapshot?, subreddit: String? = nil, maxPoints: Int = 120) -> [(date: Date, value: Int)] {
        func value(_ s: KarmaSnapshot) -> Int {
            if let sub = subreddit { return s.karma(in: sub)?.total ?? 0 }
            return s.total
        }
        var list = snapshots
        if let start = period.start(now: now) {
            let inside = snapshots.filter { $0.date >= start }
            if let base = baseline(at: start), base.date < start { list = [base] + inside } else { list = inside }
        }
        if let c = current, list.last.map({ $0.date < c.date }) ?? true { list.append(c) }
        return KarmaMath.downsample(list.map { (date: $0.date, value: value($0)) }, max: maxPoints)
    }

    func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            try enc.encode(snapshots).write(to: url, options: .atomic)
        } catch {
            NSLog("Krma: couldn't save history: \(error.localizedDescription)")
        }
    }
}
