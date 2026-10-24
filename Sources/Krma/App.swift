import AppKit
import Combine
import SwiftUI

/// NSStatusItem + NSPopover (rather than MenuBarExtra, which forces template rendering on the
/// label and would lose the green/red change colors), plus the krma:// URL handler for sign-in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = KarmaStore()
    lazy var signIn = RedditSignIn(vault: store.vault)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageOnly

        let host = NSHostingController(rootView: PopoverView(store: store, signIn: signIn) { [weak self] in self?.openSettings() })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.applyTheme() }
            .store(in: &cancellables)

        applyTheme()
        if UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled) {
            store.notifier.requestAuthorization()
        }
        updateIcon()
        signIn.onSignedIn = { [weak self] in
            Task { await self?.store.refresh(notify: false, force: true) }
        }
        signIn.onSignedOut = { [weak self] in
            Task { await self?.store.refresh(notify: false) }
        }
        store.onRevoked = { [weak self] in self?.signIn.markRevoked() }
        store.start()
    }

    /// Reddit's redirect (`krma://oauth?code=…`) arrives here, launching the app if needed.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where signIn.handle(url: url) {
            if !popover.isShown { togglePopover() }
        }
    }

    private var appliedTheme: ThemeChoice?

    /// Only on a real change: re-setting the appearance on every UserDefaults write (which
    /// happens per keystroke in Settings) resets the key window's focus mid-typing.
    private func applyTheme() {
        let choice = ThemeChoice.current
        guard choice != appliedTheme || settingsWindow?.appearance != choice.appearance else { return }
        appliedTheme = choice
        popover.appearance = choice.appearance
        settingsWindow?.appearance = choice.appearance
    }

    private func updateIcon() {
        statusItem.button?.image = MenuBarIconRenderer.render(store: store)
        statusItem.button?.toolTip = tooltip
    }

    private var tooltip: String {
        guard let c = store.current else { return "Krma — Reddit karma" }
        var lines = [store.account.map { "u/\($0.name)" } ?? "Krma", "\(KarmaMath.exact(c.total)) karma"]
        let period = Period.current
        if let d = store.delta(period) { lines.append("\(KarmaMath.signed(d.total)) \(period.label)") }
        for row in store.favoriteRows.prefix(5) {
            lines.append("r/\(row.name): \(KarmaMath.exact(row.karma.total))")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate first: as a menu-bar-only app Krma is otherwise never the active app, and
            // the popover's controls then draw in macOS's dimmed "inactive window" style.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, signIn: signIn)))
            w.title = "Krma Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            applyTheme()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
