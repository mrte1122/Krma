import Foundation

/// Karma inside one subreddit. Encoded with short keys because a snapshot holds one per subreddit.
struct SubKarma: Codable, Equatable, Hashable {
    var post: Int
    var comment: Int
    var total: Int { post + comment }

    enum CodingKeys: String, CodingKey { case post = "p", comment = "c" }
    static let zero = SubKarma(post: 0, comment: 0)
}

/// One reading of the account, as stored in history.json.
struct KarmaSnapshot: Codable, Equatable {
    let date: Date
    let total: Int
    let post: Int
    let comment: Int
    let awardee: Int
    let awarder: Int
    /// Keyed by the subreddit's display name as Reddit returns it (case preserved).
    let subreddits: [String: SubKarma]

    /// Everything except the timestamp.
    func sameValues(as o: KarmaSnapshot) -> Bool {
        total == o.total && post == o.post && comment == o.comment && awardee == o.awardee
            && awarder == o.awarder && subreddits == o.subreddits
    }

    func karma(in subreddit: String) -> SubKarma? {
        if let k = subreddits[subreddit] { return k }
        let lower = subreddit.lowercased()
        return subreddits.first { $0.key.lowercased() == lower }?.value
    }
}

struct Account: Equatable {
    let name: String
    let iconURL: URL?
    let created: Date?
    let inboxCount: Int?
}

/// A subscription (from /subreddits/mine/subscriber), merged into the pick list.
struct SubredditInfo: Equatable, Identifiable {
    let name: String
    let subscribers: Int?
    let iconURL: URL?
    var id: String { name.lowercased() }
}

/// A subreddit with its karma, for the popover lists.
struct SubredditKarma: Identifiable, Equatable {
    let name: String
    let karma: SubKarma
    var id: String { name.lowercased() }
}

/// Change between a baseline snapshot and the current one.
struct Delta: Equatable {
    let total: Int
    let post: Int
    let comment: Int
    /// Per-subreddit total change, keyed by lowercased name; only non-zero entries.
    let subreddits: [String: Int]
    /// When the baseline was taken.
    let since: Date
    /// True when history was shorter than the period, so `since` is later than the period start.
    let truncated: Bool
}

/// Reddit's rate-limit headers from the latest response.
struct RateLimit: Equatable {
    let used: Int
    let remaining: Int
    let resetAt: Date
}
