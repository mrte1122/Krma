import AppKit
import Foundation

/// Theme for the popover and Settings window. The menu-bar item always follows the menu bar.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    /// nil means "inherit the system appearance".
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    static var current: ThemeChoice {
        ThemeChoice(rawValue: UserDefaults.standard.string(forKey: SettingsKey.theme) ?? "") ?? .system
    }
}

/// The window the "change" numbers are measured over.
enum Period: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All"
        }
    }
    /// Short word for chips and the menu bar tooltip.
    var label: String {
        switch self {
        case .today: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .all: return "overall"
        }
    }
    /// Baseline instant; nil means "the earliest snapshot".
    func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        case .all: return nil
        }
    }
    static var current: Period {
        Period(rawValue: UserDefaults.standard.string(forKey: SettingsKey.period) ?? "") ?? .today
    }
}

/// `--demo`: sample data instead of your account. No network, no notifications, no update checks.
enum Demo {
    static let isActive = CommandLine.arguments.contains("--demo")
}

enum SettingsKey {
    static let refreshInterval = "refreshInterval"        // seconds, 60...1800
    static let theme = "theme"
    static let period = "period"                          // Period raw value
    static let favorites = "favoriteSubreddits"           // ordered [String]
    static let menuBarIcon = "menuBarIcon"
    static let menuBarTotal = "menuBarTotal"
    static let menuBarChange = "menuBarChange"
    static let menuBarFavorites = "menuBarFavorites"      // 0...3 favorites shown in the menu bar
    static let menuBarFavoriteChange = "menuBarFavoriteChange"
    static let exactNumbers = "exactNumbers"
    static let monochrome = "monochrome"
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyMilestones = "notifyMilestones"
    static let notifyChanges = "notifyChanges"
    static let changeThreshold = "changeThreshold"        // karma points per refresh; 0 = off
    static let sentNotifications = "sentNotifications"
    static let redditClientID = "redditClientID"          // overrides RedditSignIn.defaultClientID
    static let accessTokenExpiry = "accessTokenExpiry"    // Date
    static let showAllSubreddits = "showAllSubreddits"    // popover disclosure state
    static let autoUpdateCheck = "autoUpdateCheck"
    static let lastUpdateCheck = "lastUpdateCheck"        // Date
    static let notifiedUpdateVersion = "notifiedUpdateVersion"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshInterval: 300.0,
            theme: ThemeChoice.system.rawValue,
            period: Period.today.rawValue,
            favorites: [String](),
            menuBarIcon: true,
            menuBarTotal: true,
            menuBarChange: true,
            menuBarFavorites: 0,
            menuBarFavoriteChange: true,
            exactNumbers: false,
            monochrome: false,
            notificationsEnabled: true,
            notifyMilestones: true,
            notifyChanges: true,
            changeThreshold: 25.0,
            redditClientID: "",
            showAllSubreddits: false,
            autoUpdateCheck: true,
        ])
    }
}

enum Links {
    static let repo = URL(string: "https://github.com/mrte1122/Krma")!
    static let redditApps = URL(string: "https://www.reddit.com/prefs/apps")!
    static let redditAccessRequest = URL(string: "https://support.reddithelp.com/hc/en-us/requests/new?ticket_form_id=14868593862164&tf_42139884615700=api_request_type_developer_clone")!
    static let redditAuthorizedApps = URL(string: "https://www.reddit.com/settings/privacy")!
    static func subreddit(_ name: String) -> URL { URL(string: "https://www.reddit.com/r/\(name)/")! }
    static func user(_ name: String) -> URL { URL(string: "https://www.reddit.com/user/\(name)/")! }
}
