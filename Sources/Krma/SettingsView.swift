import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: KarmaStore
    @ObservedObject var updater: Updater
    @ObservedObject var signIn: RedditSignIn

    var body: some View {
        TabView {
            GeneralSettings(store: store, updater: updater).tabItem { Label("General", systemImage: "gearshape") }
            SubredditSettings(store: store).tabItem { Label("Subreddits", systemImage: "star") }
            AppearanceSettings(store: store).tabItem { Label("Appearance", systemImage: "menubar.rectangle") }
            AccountSettings(store: store, signIn: signIn).tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .padding(16)
        .frame(width: 500, height: 460)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: KarmaStore
    @ObservedObject var updater: Updater
    @AppStorage(SettingsKey.autoUpdateCheck) private var autoUpdate = true
    @AppStorage(SettingsKey.refreshInterval) private var interval = 300.0
    @AppStorage(SettingsKey.notificationsEnabled) private var notifications = true
    @AppStorage(SettingsKey.notifyMilestones) private var milestones = true
    @AppStorage(SettingsKey.notifyChanges) private var changes = true
    @AppStorage(SettingsKey.changeThreshold) private var threshold = 25.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var diagnosticsCopied = false

    private var intervalText: String {
        let m = Int(interval) / 60
        return m == 1 ? "Every minute" : "Every \(m) minutes"
    }

    private var updateStatus: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .upToDate: return "Krma is up to date."
        case .noReleases: return "No releases have been published yet."
        case .available(let r): return "Version \(r.version) is available."
        case .installing(let step): return step
        case .failed(let message): return message
        case .idle:
            return updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Not checked yet."
        }
    }

    var body: some View {
        Form {
            Section("Refresh") {
                Slider(value: $interval, in: KarmaStore.minInterval...KarmaStore.maxInterval, step: 60) {
                    Text(intervalText)
                } minimumValueLabel: { Text("1m") } maximumValueLabel: { Text("30m") }
                Text("Each refresh is two Reddit API calls out of the 100 per minute Reddit allows. Krma also refreshes when your Mac wakes or the network comes back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Allow notifications", isOn: $notifications)
                    .onChange(of: notifications) { _, on in if on { store.notifier.requestAuthorization() } }
                Group {
                    Toggle("Milestones (1k, 5k, 10k… and favorites' 100, 500, 1k…)", isOn: $milestones)
                    Toggle("Jumps between two refreshes", isOn: $changes)
                    TextField("Jump size (karma points; 0 turns it off)", value: $threshold, format: .number)
                        .disabled(!changes)
                }
                .disabled(!notifications)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("About") {
                LabeledContent("Version", value: Updater.currentVersion)
                HStack {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let release = updater.availableRelease {
                        Button("Install \(release.version)") { Task { await updater.install(release) } }
                    } else {
                        Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
                            .disabled(updater.state == .checking)
                    }
                }
                Toggle("Check for updates automatically (daily)", isOn: $autoUpdate)
                Link("Source on GitHub", destination: Links.repo)
                HStack {
                    Text("Krma is free and open source. Diagnostics never include your tokens.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(diagnosticsCopied ? "Copied" : "Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.diagnosticsText(), forType: .string)
                        diagnosticsCopied = true
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Favorites: order, add, remove, and how many go in the menu bar.
private struct SubredditSettings: View {
    @ObservedObject var store: KarmaStore
    @AppStorage(SettingsKey.menuBarFavorites) private var menuBarCount = 0
    @State private var newName = ""

    private var suggestions: [SubredditKarma] {
        let f = newName.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "r/", with: "")
        guard !f.isEmpty else { return [] }
        return store.allSubreddits.filter { $0.name.lowercased().contains(f) && !store.isFavorite($0.name) }.prefix(5).map { $0 }
    }

    private func add(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if !store.isFavorite(n) { store.toggleFavorite(n) }
        newName = ""
    }

    var body: some View {
        Form {
            Section("Favorites") {
                if store.favorites.isEmpty {
                    Text("No favorites yet. Add one below, or star a subreddit in the popover.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(store.favoriteRows) { row in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                Text("r/\(row.name)")
                                Spacer()
                                Text(KarmaMath.exact(row.karma.total)).monospacedDigit().foregroundStyle(.secondary)
                                Button {
                                    store.toggleFavorite(row.name)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                            }
                        }
                        .onMove { store.moveFavorites(from: $0, to: $1) }
                        .onDelete { idx in store.setFavorites(store.favorites.enumerated().filter { !idx.contains($0.offset) }.map(\.element)) }
                    }
                    .frame(height: min(180, CGFloat(store.favorites.count) * 28 + 12))
                    Text("Drag to reorder. The first ones are what the menu bar shows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Add a subreddit (e.g. swift)", text: $newName).onSubmit { add(newName) }
                    Button("Add") { add(newName) }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !suggestions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(suggestions) { s in
                            Button("r/\(s.name)") { add(s.name) }.controlSize(.small)
                        }
                    }
                }
            }
            Section("Menu bar") {
                Stepper("Show the first \(menuBarCount) favorite\(menuBarCount == 1 ? "" : "s") in the menu bar", value: $menuBarCount, in: 0...3)
                Text("Each favorite shows its name, karma and change. Three is the most that fits comfortably.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var store: KarmaStore
    @AppStorage(SettingsKey.theme) private var theme = ThemeChoice.system.rawValue
    @AppStorage(SettingsKey.menuBarIcon) private var icon = true
    @AppStorage(SettingsKey.menuBarTotal) private var total = true
    @AppStorage(SettingsKey.menuBarChange) private var change = true
    @AppStorage(SettingsKey.menuBarFavoriteChange) private var favoriteChange = true
    @AppStorage(SettingsKey.menuBarFavorites) private var menuBarCount = 0
    @AppStorage(SettingsKey.exactNumbers) private var exact = false
    @AppStorage(SettingsKey.monochrome) private var monochrome = false
    @AppStorage(SettingsKey.period) private var period = Period.today.rawValue

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Popover and Settings", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("System follows your Mac's Light or Dark setting. The menu-bar item always matches the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                MenuBarPreview(store: store)
                Toggle("Upvote glyph", isOn: $icon)
                Toggle("Total karma", isOn: $total)
                Toggle("Change over the selected period (▲ / ▼)", isOn: $change)
                Stepper("Favorites: \(menuBarCount)", value: $menuBarCount, in: 0...3)
                Toggle("Show each favorite's change too", isOn: $favoriteChange).disabled(menuBarCount == 0)
                Toggle("Exact numbers (12,431 instead of 12.4k)", isOn: $exact)
                Toggle("Monochrome (adapts to light and dark menu bars)", isOn: $monochrome)
            }
            Section("Change period") {
                Picker("Measure changes over", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("Also switchable at the top of the popover. Today means since local midnight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Live render of the status item on a light and a dark strip.
private struct MenuBarPreview: View {
    @ObservedObject var store: KarmaStore

    var body: some View {
        HStack(spacing: 8) {
            strip(appearance: .aqua, background: Color(white: 0.93))
            strip(appearance: .darkAqua, background: Color(white: 0.16))
        }
        .frame(height: 30)
    }

    private func strip(appearance: NSAppearance.Name, background: Color) -> some View {
        let image = MenuBarIconRenderer.render(store: store)
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(background)
            MenuBarImage(image: image, appearance: appearance)
        }
    }
}

/// NSImageView host so template images tint the way the real menu bar does.
private struct MenuBarImage: NSViewRepresentable {
    let image: NSImage
    let appearance: NSAppearance.Name

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleNone
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        v.image = image
        v.appearance = NSAppearance(named: appearance)
        v.contentTintColor = appearance == .darkAqua ? .white : .black
    }
}

private struct AccountSettings: View {
    @ObservedObject var store: KarmaStore
    @ObservedObject var signIn: RedditSignIn
    @State private var clientID = UserDefaults.standard.string(forKey: SettingsKey.redditClientID) ?? ""
    @State private var savedID = UserDefaults.standard.string(forKey: SettingsKey.redditClientID) ?? ""

    private func saveClientID() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(id, forKey: SettingsKey.redditClientID)
        clientID = id
        savedID = id
    }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Account", value: store.account.map { "u/\($0.name)" } ?? "Not connected")
                if let created = store.account?.created {
                    LabeledContent("Member since", value: created.formatted(date: .abbreviated, time: .omitted))
                }
                if let r = store.rateLimit {
                    LabeledContent("API this window", value: "\(r.used) used · \(r.remaining) left · resets in \(max(0, Int(r.resetAt.timeIntervalSince(store.now)) / 60 + 1)) min")
                }
                LabeledContent("History", value: store.history.first.map { "since \($0.date.formatted(date: .abbreviated, time: .omitted)) · \(store.history.snapshots.count) snapshots" } ?? "empty")
            }
            Section("Reddit sign-in") {
                if signIn.isSignedIn {
                    HStack {
                        Label("Signed in with Reddit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Sign Out") { signIn.signOut() }
                    }
                    Text("Signing out revokes the token with Reddit and removes it from this Mac. Your local history stays. You can also revoke it under Reddit → Settings → Privacy → Third-party app authorizations.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SignInCard(signIn: signIn)
                }
            }
            Section("Client ID") {
                HStack {
                    TextField(RedditAuth.defaultClientID.isEmpty ? "Required: your installed app's ID" : "Optional: use your own app instead of the built-in one", text: $clientID)
                        .onSubmit(saveClientID)
                    Button("Save", action: saveClientID)
                        .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines) == savedID)
                }
                if !savedID.isEmpty, savedID.count < 10 {
                    Text("The saved ID \"\(savedID)\" is too short to be a Reddit client ID (they're 14–30 characters).")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(RedditAuth.defaultClientID.isEmpty
                         ? "Reddit requires every client to be registered. Create an installed app with redirect URI krma://oauth at reddit.com/prefs/apps and paste its ID."
                         : "Leave empty to use Krma's own registration. Paste your own installed app's ID to run on your own API quota.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Link("Open prefs/apps", destination: Links.redditApps).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}
