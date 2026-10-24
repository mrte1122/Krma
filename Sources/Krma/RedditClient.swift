import Foundation

enum RedditError: LocalizedError {
    case unauthorized
    case rateLimited(Int)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Reddit rejected the sign-in (401)."
        case .rateLimited(let s): return "Reddit's rate limit was hit; it resets in \(max(1, s / 60)) min."
        case .http(let code, let m): return "Reddit returned \(code)\(m.isEmpty ? "" : ": \(m)")"
        case .decoding(let m): return "Unexpected response from Reddit (\(m))."
        }
    }
}

struct Me: Equatable {
    let name: String
    let total: Int
    let post: Int
    let comment: Int
    let awardee: Int
    let awarder: Int
    let iconURL: URL?
    let created: Date?
    let inboxCount: Int?
}

struct RedditClient {
    let vault: TokenVault
    var userHint: String?
    /// Reddit's rate-limit headers from each response.
    var onRateLimit: (@Sendable (RateLimit) -> Void)?
    static let base = URL(string: "https://oauth.reddit.com")!

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var token = try await vault.accessToken()
        for attempt in 0..<2 {
            var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            comps.queryItems = query + [URLQueryItem(name: "raw_json", value: "1")]
            var req = URLRequest(url: comps.url!)
            req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(RedditAuth.userAgent(user: userHint), forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw RedditError.http(-1, "No HTTP response") }
            if let used = http.value(forHTTPHeaderField: "x-ratelimit-used").flatMap(Double.init),
               let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Double.init),
               let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init) {
                onRateLimit?(RateLimit(used: Int(used), remaining: Int(remaining), resetAt: Date().addingTimeInterval(reset)))
            }
            switch http.statusCode {
            case 200..<300: return data
            case 401 where attempt == 0:
                token = try await vault.accessToken(forceRefresh: true)
                continue
            case 401: throw RedditError.unauthorized
            case 429:
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init) ?? 60
                throw RedditError.rateLimited(Int(reset))
            default:
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
                throw RedditError.http(http.statusCode, msg)
            }
        }
        throw RedditError.unauthorized
    }

    func fetchMe() async throws -> Me {
        struct R: Decodable {
            let name: String
            let total_karma: Int?
            let link_karma: Int?
            let comment_karma: Int?
            let awardee_karma: Int?
            let awarder_karma: Int?
            let icon_img: String?
            let created_utc: Double?
            let inbox_count: Int?
        }
        let data = try await get("api/v1/me")
        let r: R
        do { r = try JSONDecoder().decode(R.self, from: data) } catch { throw RedditError.decoding("me: \(error.localizedDescription)") }
        let post = r.link_karma ?? 0, comment = r.comment_karma ?? 0, awardee = r.awardee_karma ?? 0, awarder = r.awarder_karma ?? 0
        return Me(name: r.name, total: r.total_karma ?? (post + comment + awardee + awarder),
                  post: post, comment: comment, awardee: awardee, awarder: awarder,
                  iconURL: Self.iconURL(r.icon_img), created: r.created_utc.map { Date(timeIntervalSince1970: $0) },
                  inboxCount: r.inbox_count)
    }

    /// Per-subreddit karma, the "local karma" moderators see. One entry per subreddit with any karma.
    func fetchKarmaBreakdown() async throws -> [SubredditKarma] {
        struct Item: Decodable { let sr: String; let comment_karma: Int?; let link_karma: Int? }
        struct R: Decodable { let data: [Item]? }
        let data = try await get("api/v1/me/karma")
        let r: R
        do { r = try JSONDecoder().decode(R.self, from: data) } catch { throw RedditError.decoding("karma: \(error.localizedDescription)") }
        return (r.data ?? []).map { SubredditKarma(name: $0.sr, karma: SubKarma(post: $0.link_karma ?? 0, comment: $0.comment_karma ?? 0)) }
    }

    /// Subscriptions, up to `maxPages` × 100.
    func fetchSubscriptions(maxPages: Int = 5) async throws -> [SubredditInfo] {
        struct Sub: Decodable { let display_name: String; let subscribers: Int?; let icon_img: String?; let community_icon: String? }
        struct Child: Decodable { let data: Sub }
        struct Listing: Decodable { let after: String?; let children: [Child] }
        struct R: Decodable { let data: Listing }
        var out: [SubredditInfo] = []
        var after: String?
        for _ in 0..<maxPages {
            var q = [URLQueryItem(name: "limit", value: "100")]
            if let a = after { q.append(URLQueryItem(name: "after", value: a)) }
            let data = try await get("subreddits/mine/subscriber", query: q)
            let r: R
            do { r = try JSONDecoder().decode(R.self, from: data) } catch { throw RedditError.decoding("subscriptions: \(error.localizedDescription)") }
            out += r.data.children.map {
                SubredditInfo(name: $0.data.display_name, subscribers: $0.data.subscribers,
                              iconURL: Self.iconURL($0.data.community_icon) ?? Self.iconURL($0.data.icon_img))
            }
            guard let next = r.data.after, !next.isEmpty else { break }
            after = next
        }
        return out
    }

    /// Reddit HTML-escapes URLs unless raw_json=1 is honored; unescape defensively and drop blanks.
    static func iconURL(_ s: String?) -> URL? {
        guard var s, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: s)
    }
}
