import Foundation

enum KarmaMath {
    /// 999 → "999", 1234 → "1.2k", 12345 → "12.3k", 123456 → "123k", 1234567 → "1.2M".
    /// One decimal is kept below 100k because a 12,431 → 12,500 move should still show in the menu bar.
    static func compact(_ n: Int) -> String {
        let sign = n < 0 ? "−" : ""
        let v = abs(n)
        func one(_ x: Double, _ suffix: String) -> String {
            let s = String(format: "%.1f", x)
            return sign + (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        switch v {
        case ..<1000: return sign + String(v)
        case ..<100_000: return one(Double(v) / 1000, "k")
        case ..<1_000_000: return sign + String(v / 1000) + "k"
        case ..<10_000_000: return one(Double(v) / 1_000_000, "M")
        default: return sign + String(v / 1_000_000) + "M"
        }
    }

    static func exact(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    static func number(_ n: Int, exact useExact: Bool) -> String {
        useExact ? exact(n) : compact(n)
    }

    /// "+37", "−3", "0". Uses a real minus sign so columns line up with the ▲▼ chips.
    static func signed(_ n: Int, exact useExact: Bool = true) -> String {
        let body = useExact ? exact(abs(n)) : compact(abs(n))
        return n > 0 ? "+" + body : n < 0 ? "−" + body : "0"
    }

    /// Change between two snapshots. Subreddits missing from the baseline count from zero.
    static func delta(from base: KarmaSnapshot, to cur: KarmaSnapshot, truncated: Bool) -> Delta {
        var subs: [String: Int] = [:]
        let baseByLower = Dictionary(base.subreddits.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        for (name, k) in cur.subreddits {
            let key = name.lowercased()
            seen.insert(key)
            let d = k.total - (baseByLower[key]?.total ?? 0)
            if d != 0 { subs[key] = d }
        }
        for (key, k) in baseByLower where !seen.contains(key) && k.total != 0 {
            subs[key] = -k.total
        }
        return Delta(total: cur.total - base.total, post: cur.post - base.post, comment: cur.comment - base.comment,
                     subreddits: subs, since: base.date, truncated: truncated)
    }

    // MARK: Milestones

    static let totalLadder: [Int] = [100, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
    static let subredditLadder: [Int] = [100, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000]

    /// Milestones crossed going up from `old` to `new`, ascending. Above the ladder: every 500k.
    static func milestones(from old: Int, to new: Int, ladder: [Int], beyondStep: Int? = nil) -> [Int] {
        guard new > old else { return [] }
        var hits = ladder.filter { $0 > old && $0 <= new }
        if let step = beyondStep, let top = ladder.last, new > top {
            var m = max(top, old / step * step) + step
            while m <= new {
                if m > old && !hits.contains(m) { hits.append(m) }
                m += step
            }
        }
        return hits.sorted()
    }

    // MARK: History thinning

    /// Keeps every snapshot from the last `fullDays`, the last snapshot of each local day beyond
    /// that, and nothing older than `maxDays`.
    static func prune(_ snapshots: [KarmaSnapshot], now: Date, fullDays: Int = 7, maxDays: Int = 730,
                      calendar: Calendar = .current) -> [KarmaSnapshot] {
        let sorted = snapshots.sorted { $0.date < $1.date }
        let fullCutoff = now.addingTimeInterval(-Double(fullDays) * 86_400)
        let dropCutoff = now.addingTimeInterval(-Double(maxDays) * 86_400)
        var out: [KarmaSnapshot] = []
        var lastDay: Date?
        for s in sorted where s.date >= dropCutoff {
            if s.date >= fullCutoff {
                out.append(s)
            } else {
                let day = calendar.startOfDay(for: s.date)
                if lastDay == day, !out.isEmpty { out.removeLast() }
                out.append(s)
                lastDay = day
            }
        }
        return out
    }

    /// Thin a series to at most `max` points for the sparkline, always keeping the ends.
    static func downsample<T>(_ points: [T], max: Int) -> [T] {
        guard points.count > max, max >= 2 else { return points }
        let step = Double(points.count - 1) / Double(max - 1)
        return (0..<max).map { points[Int((Double($0) * step).rounded())] }
    }

    /// "3m ago", "2h ago", "Oct 12".
    static func relative(_ d: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// `Krma --selftest`: pure-logic checks that need no network and no account.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }

        check(KarmaMath.compact(0) == "0", "compact 0")
        check(KarmaMath.compact(999) == "999", "compact 999")
        check(KarmaMath.compact(1_000) == "1k", "compact 1000")
        check(KarmaMath.compact(1_234) == "1.2k", "compact 1234")
        check(KarmaMath.compact(9_950) == "10k" || KarmaMath.compact(9_950) == "9.9k" || KarmaMath.compact(9_950) == "10.0k", "compact 9950 rounds")
        check(KarmaMath.compact(12_345) == "12.3k", "compact 12345")
        check(KarmaMath.compact(99_949) == "99.9k", "compact 99949")
        check(KarmaMath.compact(123_456) == "123k", "compact 123456")
        check(KarmaMath.compact(1_234_567) == "1.2M", "compact 1.2M")
        check(KarmaMath.compact(-1_500) == "−1.5k", "compact negative")
        check(KarmaMath.signed(37) == "+37" && KarmaMath.signed(-3) == "−3" && KarmaMath.signed(0) == "0", "signed")

        check(KarmaMath.milestones(from: 950, to: 1_020, ladder: KarmaMath.totalLadder) == [1_000], "milestone single")
        check(KarmaMath.milestones(from: 400, to: 2_600, ladder: KarmaMath.totalLadder) == [500, 1_000, 2_500], "milestone multiple")
        check(KarmaMath.milestones(from: 1_000, to: 1_000, ladder: KarmaMath.totalLadder).isEmpty, "milestone none when flat")
        check(KarmaMath.milestones(from: 2_000, to: 1_000, ladder: KarmaMath.totalLadder).isEmpty, "milestone none when falling")
        check(KarmaMath.milestones(from: 1_400_000, to: 2_100_000, ladder: KarmaMath.totalLadder, beyondStep: 500_000) == [1_500_000, 2_000_000], "milestone beyond ladder")
        check(KarmaMath.milestones(from: 999_000, to: 1_600_000, ladder: KarmaMath.totalLadder, beyondStep: 500_000) == [1_000_000, 1_500_000], "milestone ladder top then beyond")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let base = KarmaSnapshot(date: t0, total: 1_000, post: 600, comment: 400, awardee: 0, awarder: 0,
                                 subreddits: ["swift": SubKarma(post: 100, comment: 50), "gone": SubKarma(post: 10, comment: 0)])
        let cur = KarmaSnapshot(date: t0.addingTimeInterval(3600), total: 1_040, post: 620, comment: 420, awardee: 0, awarder: 0,
                                subreddits: ["Swift": SubKarma(post: 120, comment: 60), "apple": SubKarma(post: 5, comment: 5)])
        let d = KarmaMath.delta(from: base, to: cur, truncated: false)
        check(d.total == 40 && d.post == 20 && d.comment == 20, "delta totals")
        check(d.subreddits["swift"] == 30, "delta subreddit case-insensitive")
        check(d.subreddits["apple"] == 10, "delta new subreddit counts from zero")
        check(d.subreddits["gone"] == -10, "delta vanished subreddit counts down")
        check(base.karma(in: "SWIFT")?.post == 100, "karma(in:) case-insensitive")

        // Pruning: 10 days of hourly snapshots → the last 7 days intact, one per day before that.
        let now = Date()
        let cal = Calendar.current
        var many: [KarmaSnapshot] = []
        for h in stride(from: 0, to: 10 * 24, by: 1) {
            many.append(KarmaSnapshot(date: now.addingTimeInterval(-Double(h) * 3600), total: h, post: 0, comment: 0,
                                      awardee: 0, awarder: 0, subreddits: [:]))
        }
        let pruned = KarmaMath.prune(many, now: now, fullDays: 7, calendar: cal)
        let recent = pruned.filter { $0.date >= now.addingTimeInterval(-7 * 86_400) }.count
        let old = pruned.filter { $0.date < now.addingTimeInterval(-7 * 86_400) }
        let oldDays = Set(old.map { cal.startOfDay(for: $0.date) })
        check(recent == 7 * 24 + 1 || recent == 7 * 24, "prune keeps recent (\(recent))")
        check(old.count == oldDays.count && old.count >= 3, "prune thins old to one per day (\(old.count))")
        check(pruned == pruned.sorted { $0.date < $1.date }, "prune keeps order")
        check(KarmaMath.prune(many, now: now, fullDays: 7, maxDays: 8, calendar: cal).allSatisfy { $0.date >= now.addingTimeInterval(-8 * 86_400) }, "prune drops beyond maxDays")

        check(KarmaMath.downsample(Array(0..<100), max: 10).count == 10, "downsample count")
        check(KarmaMath.downsample(Array(0..<100), max: 10).first == 0 && KarmaMath.downsample(Array(0..<100), max: 10).last == 99, "downsample keeps ends")
        check(KarmaMath.downsample([1, 2, 3], max: 10) == [1, 2, 3], "downsample passthrough")

        // History baseline rules.
        let h = History(url: nil)
        _ = h.record(base)
        check(h.record(KarmaSnapshot(date: t0.addingTimeInterval(60), total: 1_000, post: 600, comment: 400, awardee: 0, awarder: 0, subreddits: base.subreddits)) == false, "history skips unchanged")
        check(h.record(cur) == true, "history records change")
        check(h.record(KarmaSnapshot(date: cur.date.addingTimeInterval(90_000), total: cur.total, post: cur.post, comment: cur.comment, awardee: 0, awarder: 0, subreddits: cur.subreddits)) == true, "history records daily even if unchanged")
        check(h.baseline(at: t0.addingTimeInterval(1800))?.date == t0, "baseline latest at or before")
        check(h.baseline(at: t0.addingTimeInterval(-10))?.date == t0, "baseline falls back to earliest")
        check(h.delta(period: .all, now: cur.date.addingTimeInterval(90_000), current: cur)?.total == 40, "history delta all")

        let enc = try? JSONEncoder().encode(cur)
        let dec = enc.flatMap { try? JSONDecoder().decode(KarmaSnapshot.self, from: $0) }
        check(dec == cur, "snapshot round-trips")
        check(enc.map { String(decoding: $0, as: UTF8.self).contains("\"p\":") } == true, "snapshot uses short keys")

        print(failures == 0 ? "All self-tests passed." : "\(failures) self-test(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
