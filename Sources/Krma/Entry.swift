import AppKit
import ServiceManagement

@main
enum Entry {
    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so CLI modes print immediately even when piped
        SettingsKey.registerDefaults()
        let args = CommandLine.arguments

        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--once") { runOnce() }
        if args.contains("--sign-in") { runSignIn() }
        if args.contains("--check-update") || args.contains("--update") {
            runUpdate(install: args.contains("--update"))
        }
        if let i = args.firstIndex(of: "--launch-at-login"), i + 1 < args.count {
            let service = SMAppService.mainApp
            do {
                if args[i + 1] == "on" { try service.register() } else { try service.unregister() }
            } catch {
                print("error:", error.localizedDescription)
            }
            print("launch at login:", service.status == .enabled ? "enabled" : "status \(service.status.rawValue)")
            exit(service.status == .enabled ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { Snapshot.run(outDir: args[i + 1]) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, like LSUIElement
        app.run()
    }

    /// Fetch once and print a summary (never the tokens).
    @MainActor
    private static func runOnce() -> Never {
        let store = KarmaStore()
        Task { @MainActor in
            await store.refresh(notify: false, force: true)
            print(store.diagnosticsText())
            if store.needsSignIn { print("not signed in: run `Krma --sign-in` or use the popover") }
            exit(store.lastError == nil && !store.needsSignIn ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--sign-in`: the same flow as the button, driven from the terminal. Since a bare binary has
    /// no URL scheme, paste the krma://oauth?… address the browser ends up on.
    @MainActor
    private static func runSignIn() -> Never {
        _ = NSApplication.shared
        let store = KarmaStore()
        let signIn = RedditSignIn(vault: store.vault)
        guard signIn.hasClientID else {
            print("error: no client ID. Register an installed app (redirect URI krma://oauth) at reddit.com/prefs/apps and run:")
            print("  defaults write io.github.mrte1122.Krma redditClientID <id>")
            exit(1)
        }
        signIn.start(openBrowser: false)
        guard case .waiting(let url) = signIn.state else { print("error: couldn't start sign-in"); exit(1) }
        print("Open this address, approve Krma, then paste the krma://oauth?… address the browser lands on:")
        print(url.absoluteString)
        print("\nRedirect URL: ", terminator: "")
        guard let line = readLine(), !line.isEmpty else { print("error: nothing pasted"); exit(1) }
        signIn.handlePasted(line)
        Task { @MainActor in
            while true {
                switch signIn.state {
                case .failed(let message):
                    print("error:", message); exit(1)
                case .idle where signIn.isSignedIn:
                    await store.refresh(notify: false, force: true)
                    print(store.diagnosticsText())
                    exit(store.lastError == nil ? 0 : 1)
                default: break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--check-update` reports the latest release; `--update` also installs it (no relaunch).
    @MainActor
    private static func runUpdate(install: Bool) -> Never {
        _ = NSApplication.shared
        let updater = Updater()
        Task { @MainActor in
            print("installed:", Updater.currentVersion, "at", Bundle.main.bundleURL.path)
            print("install location:", Updater.installLocationProblem ?? "ok, updates can install here")
            await updater.check(userInitiated: true)
            switch updater.state {
            case .available(let release):
                print("available:", release.version)
                if install {
                    await updater.install(release, relaunch: false)
                    if case .failed(let message) = updater.state { print("error:", message); exit(1) }
                    let plist = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
                    print("installed now:", plist?["CFBundleShortVersionString"] as? String ?? "?")
                }
                exit(0)
            case .upToDate:
                print("up to date")
                exit(0)
            case .noReleases:
                print("no releases published yet")
                exit(0)
            case .failed(let message):
                print("error:", message)
                exit(1)
            default:
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
