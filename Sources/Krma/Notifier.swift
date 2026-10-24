import Foundation
import UserNotifications

/// Milestone and jump notifications, deduplicated through a `sentNotifications` list in UserDefaults.
@MainActor
final class Notifier {
    /// UNUserNotificationCenter traps outside a real .app bundle (e.g. `swift run`).
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled) }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `previous` is the last known reading (from this run, or history at launch); nil seeds silently.
    /// `jumpsArmed` is false for the first comparison of a run, so changes while the app was closed
    /// don't all fire at once (milestones still do, once, because they're deduplicated).
    func evaluate(previous: KarmaSnapshot?, current: KarmaSnapshot, favorites: [String], jumpsArmed: Bool) {
        guard available, enabled, let previous else { return }
        let d = UserDefaults.standard
        var sent = Set(d.stringArray(forKey: SettingsKey.sentNotifications) ?? [])

        if d.bool(forKey: SettingsKey.notifyMilestones) {
            for m in KarmaMath.milestones(from: previous.total, to: current.total, ladder: KarmaMath.totalLadder, beyondStep: 500_000) {
                let key = "total-\(m)"
                guard !sent.contains(key) else { continue }
                sent.insert(key)
                post(title: "\(KarmaMath.compact(m)) karma", body: "Your Reddit karma passed \(KarmaMath.exact(m)). It's now \(KarmaMath.exact(current.total)).")
            }
            for name in favorites {
                let old = previous.karma(in: name)?.total ?? 0
                let new = current.karma(in: name)?.total ?? 0
                for m in KarmaMath.milestones(from: old, to: new, ladder: KarmaMath.subredditLadder) {
                    let key = "sub-\(name.lowercased())-\(m)"
                    guard !sent.contains(key) else { continue }
                    sent.insert(key)
                    post(title: "r/\(name): \(KarmaMath.compact(m)) karma", body: "Your karma in r/\(name) passed \(KarmaMath.exact(m)).")
                }
            }
        }

        let threshold = Int(d.double(forKey: SettingsKey.changeThreshold))
        if jumpsArmed, d.bool(forKey: SettingsKey.notifyChanges), threshold > 0 {
            let diff = current.total - previous.total
            if abs(diff) >= threshold {
                let subs = KarmaMath.delta(from: previous, to: current, truncated: false).subreddits
                let movers = subs.sorted { abs($0.value) > abs($1.value) }.prefix(3)
                    .map { "r/\($0.key) \(KarmaMath.signed($0.value))" }
                let title = diff > 0 ? "Karma \(KarmaMath.signed(diff))" : "Karma \(KarmaMath.signed(diff))"
                post(title: title, body: movers.isEmpty ? "Now \(KarmaMath.exact(current.total))." : movers.joined(separator: " · "))
            }
        }

        d.set(Array(sent.sorted().suffix(500)), forKey: SettingsKey.sentNotifications)
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
