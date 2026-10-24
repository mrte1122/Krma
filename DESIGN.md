# Krma — Design

Krma puts your Reddit karma in the macOS menu bar: the account total, how much it moved
today (or this week / month), and the "local" karma of the subreddits you star. It is the
sibling of [Quotacat](https://github.com/mrte1122/Quotacat) and reuses its architecture: a SwiftPM
executable with no dependencies, an `NSStatusItem` + `NSPopover`, a refresh coordinator that
also fires on wake and network return, a Keychain-held credential, and a `scripts/build-app.sh`
that wraps the binary into a signed universal `.app`.

## What it shows

| Where | What |
|---|---|
| Menu bar | optional arrow glyph · total karma (`12.4k`) · change over the selected period (`▲37` green / `▼3` red) · up to three favorite subreddits (`swift 1.2k ▲12`) |
| Popover: Total card | exact total, change chip, post / comment / award split bar, sparkline of the total over the period |
| Popover: Favorites | one row per starred subreddit: post + comment karma, change over the period, open-on-Reddit link |
| Popover: All subreddits | every subreddit you have karma in, plus subscriptions with no karma yet, filterable, star to favorite |
| Notifications | total-karma milestones, favorite-subreddit milestones, and jumps of ≥ N karma between two refreshes (with the subreddits that caused it) |

"Local karma" is the per-subreddit karma Reddit itself tracks (what moderators see when they
check a user's standing in their community). Krma reads it directly rather than summing
recent posts, so it is exact and includes activity older than the 1,000-item listing limit.

## Data source

Everything comes from Reddit's OAuth API at `https://oauth.reddit.com`:

| Call | Scope | Cadence | Gives |
|---|---|---|---|
| `GET /api/v1/me` | `identity` | every refresh | `name`, `total_karma`, `link_karma`, `comment_karma`, `awardee_karma`, `awarder_karma`, `icon_img`, `created_utc`, `inbox_count` |
| `GET /api/v1/me/karma` | `mysubreddits` | every refresh | `data: [{ sr, link_karma, comment_karma }]` — one entry per subreddit where you have karma |
| `GET /subreddits/mine/subscriber?limit=100` | `mysubreddits` | every 30 min, ≤ 5 pages | subscriptions (`display_name`, `subscribers`, icons), so a subreddit can be starred before you have karma there |

Two requests per refresh. The free tier allows 100 requests per minute per client, averaged
over 10 minutes, so even the 1-minute minimum interval uses 2% of it. The `X-Ratelimit-*`
response headers are recorded and shown in Settings → Account.

Unauthenticated access (`www.reddit.com/user/<name>/about.json`) was tested on 2026-10-24 and
returns 403 for non-browser clients, so there is no "track by username" mode. Reddit requires a
descriptive User-Agent; Krma sends `macos:io.github.mrte1122.Krma:v<version> (by /u/<signed-in user>)`.

## Sign-in

Reddit's OAuth2 **authorization code flow for installed apps**, which issues no client secret:

1. The app opens `https://www.reddit.com/api/v1/authorize?client_id=…&response_type=code&state=<random>&redirect_uri=krma://oauth&duration=permanent&scope=identity mysubreddits` in the default browser.
2. Reddit redirects to `krma://oauth?code=…&state=…`. macOS launches or activates Krma
   (the bundle registers the `krma` URL scheme) and `AppDelegate.application(_:open:)` hands
   the URL to `RedditSignIn.handle(url:)`, which checks `state`.
   If the browser doesn't bounce back (for example when running the bare binary from `swift build`,
   which has no bundle and therefore no URL scheme), the sign-in card accepts the redirect URL pasted
   from the address bar.
3. `POST https://www.reddit.com/api/v1/access_token` with HTTP Basic auth `client_id:` (empty
   password), `grant_type=authorization_code&code=…&redirect_uri=krma://oauth`. The response
   carries a 1-hour `access_token` and, because `duration=permanent`, a `refresh_token`.
4. Both tokens go into the Keychain (service `Krma`, accounts `refresh-token` and
   `access-token`; the access-token expiry is kept in UserDefaults). `TokenVault` hands out the
   cached access token and refreshes it (`grant_type=refresh_token`) when it is within 60 s of
   expiring or when a call comes back 401. A refresh that fails with `invalid_grant` means the
   authorization was revoked on reddit.com: the tokens are deleted and the sign-in card returns.
5. Sign out revokes the refresh token (`POST /api/v1/revoke_token`, best effort) and deletes both
   Keychain items.

The client ID is public, like Quotacat's GitHub client ID. `RedditSignIn.defaultClientID` holds
the maintainer's registered app; Settings → Account lets anyone paste their own instead
(`redditClientID`). Registering an app is type **installed app** with redirect URI exactly `krma://oauth`
at reddit.com/prefs/apps, but since November 2025 Reddit's Responsible Builder Policy gates app creation
behind a manual access request (see `docs/reddit-api-access-request.md`); accounts that haven't been
approved can't create apps. Until a client ID is present the sign-in card explains this.

## History and deltas

Reddit only reports current karma, so Krma keeps its own history in
`~/Library/Application Support/Krma/history.json`: an array of snapshots
`{ date, total, post, comment, awardee, awarder, subreddits: { name: { p, c } } }`.

- A snapshot is appended when any value changed since the last one, or once a day regardless, so
  quiet accounts cost almost nothing and the chart still has a point per day.
- Pruning: entries older than 7 days are thinned to the last one of each local day; entries older
  than 2 years are dropped. The file is rewritten only when something was appended or pruned.
- **Period** (Today / 7 days / 30 days / All), selected in the popover and remembered: the change
  is current − baseline, where the baseline is the latest snapshot at or before the period start
  (local midnight, now − 7 d, now − 30 d), or the earliest snapshot when history is shorter than
  the period. The chip then says "since <date>" so a young history isn't mistaken for a flat one.
- Per-subreddit deltas use the same baseline; a subreddit missing from the baseline counts from 0.

Every refresh also writes `~/Library/Application Support/Krma/karma.json` (user, totals,
period change, favorites) for shell prompts and scripts.

## Notifications

Deduplicated through a `sentNotifications` list in UserDefaults, like Quotacat.

- **Milestones**: total karma crossing 100, 500, 1k, 2.5k, 5k, 10k, 25k, 50k, 100k, 250k, 500k,
  1M, then every 500k. Favorite subreddits: 100, 500, 1k, 2.5k, 5k, 10k, 25k, 50k, 100k. Crossing
  is checked against the previous known value (the last history entry at launch), so a milestone
  passed while the Mac was asleep is still announced once.
- **Jumps**: when the total moves by at least `changeThreshold` (default 25, 0 disables) between
  two consecutive refreshes in one run, one notification names the amount and the subreddits that
  moved most. Seeded silently on the first fetch of each launch.

## Menu bar

Composable rather than fixed styles. Toggles: arrow glyph, total, change, favorites (0–3), exact
numbers instead of `12.4k`, monochrome (renders as a template image so it follows the menu bar).
Positive changes are green, negative red; zero change is omitted to save width. With everything
off, or before the first fetch, the item shows the arrow glyph alone (a warning triangle after
repeated failures).

## Architecture

```
Sources/Krma/
  Entry.swift          @main; CLI modes (--selftest, --once, --sign-in, --demo, --snapshot, --launch-at-login, --check-update, --update)
  App.swift            AppDelegate: status item, popover, settings window, krma:// URL handling
  Settings.swift       UserDefaults keys and defaults, ThemeChoice, Period, Demo, Links
  Models.swift         KarmaSnapshot, SubKarma, Account, SubredditInfo, Delta
  KarmaMath.swift      compact numbers, deltas, milestone ladders, history pruning, self-tests
  Credentials.swift    Keychain storage
  RedditSignIn.swift   authorization-code flow, token exchange, TokenVault (refresh), sign out
  RedditClient.swift   /api/v1/me, /api/v1/me/karma, subscriptions, rate-limit headers
  History.swift        snapshot persistence and baseline queries
  KarmaStore.swift     refresh coordinator: timer, wake/network triggers, favorites, cache file, demo data
  Notifier.swift       milestone and jump notifications with dedup
  Updater.swift        GitHub Releases check, Ed25519 verification, in-place install, relaunch
  Theme.swift          colors and the card surface
  MenuBarIcon.swift    NSImage renderer for the status item
  PopoverView.swift    total card, sparkline, favorites, all-subreddits list, sign-in card
  SettingsView.swift   General / Subreddits / Appearance / Account
  Snapshot.swift       offscreen renders of the popover and icon (README screenshots)

scripts/
  build-app.sh         universal build, icon packing, URL-scheme Info.plist, signing, --install / --zip / --notarize
  make-icon.swift      app icon renderer (an original cat with an upvote arrow; no Reddit marks)
  release.sh           version bump, notarized build, signed zip, tag, push, GitHub release, cask bump
  sign-update.swift    Ed25519 keygen / public / sign for the update archive
```

## Updates

Same design as Quotacat's updater, with Krma's own key.

- Releases are GitHub Releases with two assets: `Krma.zip` (always that name, so
  `releases/latest/download/Krma.zip` is a permanent download link) and `Krma.zip.sig`.
- The signature is Ed25519 over the zip bytes. The private key stays on the maintainer's Mac
  (`~/.config/krma/update-signing-key`, override with `KRMA_SIGNING_KEY`; it is not Quotacat's
  key); the public key is compiled into `Updater.swift`, and `release.sh` refuses to ship if the
  two don't match.
- The app checks `GET /repos/mrte1122/Krma/releases/latest` 15 seconds after launch and then at
  most once a day, unauthenticated. A newer version shows an Update button and one notification
  per version. Background checks fail silently (offline, rate-limited, or no release published
  yet); a manual check from Settings → General or `--check-update` reports why. `--demo` never
  checks.
- Installing downloads both assets, verifies the signature, unzips with `ditto`, checks the bundle
  identifier, version and code signature, swaps the bundle in place with
  `FileManager.replaceItemAt` (or just `Contents/` when the user owns the app but not the folder),
  and relaunches through a detached `open`. Any failure leaves the installed app untouched and
  links to the releases page.
- An app opened straight from Downloads runs from a read-only App Translocation copy and can't
  update itself; the popover then shows a "Move Krma to Applications" banner and, once a copy is
  found there, offers to relaunch from it.
- Releases are signed with a Developer ID (hardened runtime) and notarized, with the ticket
  stapled, so first downloads pass Gatekeeper. Once the running app has a Developer ID team, the
  updater also requires the new bundle to come from the same team.
- The bundle is assembled and signed in `$TMPDIR`, not the repo: iCloud-synced folders like
  `~/Documents` add extended attributes that codesign rejects.
