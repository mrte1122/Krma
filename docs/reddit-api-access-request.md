# Getting Krma a Reddit client ID

Since November 2025, Reddit's [Responsible Builder Policy](https://support.reddithelp.com/hc/en-us/articles/42728983564564-Responsible-Builder-Policy)
says: *"You must request access and get explicit approval before accessing any Reddit data through our
API."* In practice, accounts that haven't been approved can no longer create apps at reddit.com/prefs/apps:
the **create app** button refreshes the page or reports an app limit of 0. Credentials created before the
change keep working, so **first check prefs/apps for any app you made in the past** and reuse it (edit it,
add `krma://oauth` as its redirect URI, copy its client ID).

Otherwise, file the developer request below. Reddit asks developers to use Devvit (apps that run on
Reddit's servers) and to use this form only when Devvit can't do the job. A native macOS app that needs
the user's own OAuth token is exactly that case.

## The form

**URL:** https://support.reddithelp.com/hc/en-us/requests/new?ticket_form_id=14868593862164&tf_42139884615700=api_request_type_developer_clone

Filling it in this way (edit the bracketed parts first):

| Field | Answer |
|---|---|
| What do you need assistance with? | Data Access Request |
| Your email address | [your email] |
| Which role best describes your reason for requesting API access? | I'm a developer |
| What is your inquiry? | I'm a developer and want to build a Reddit App that does not work in the Devvit ecosystem. |
| Your Reddit username (only the name, no u/) | [username] |
| Developer username(s) | [username] |
| Company name | n/a (the form says to use n/a for individuals) |
| Provide a link to source code or platform that will access the API | [GitHub URL of this repo once it's pushed; Quotacat's repo shows the same author's track record: https://github.com/mrte1122/Quotacat] |
| What subreddits do you intend to use the bot/app in? | None. The app reads only the signed-in user's own account data (their karma totals and per-subreddit karma breakdown). It never reads, posts or votes in any subreddit. |
| If applicable, what username will you be operating this Bot/App under? | n/a. It isn't a bot; each person signs in with their own account and the app acts only on their behalf, read-only. |
| If this is a bot that already exists… | n/a |
| What is your data budget? | < $500 / month (free tier; the app makes 2 requests per refresh, every 5 minutes by default) |

**What benefit/purpose will the bot/app have for Redditors?**

> Krma is a free, open-source (MIT) macOS menu-bar app that shows a Redditor their own karma: the account
> total, how it changed today / this week / this month, and their karma inside the subreddits they choose
> to follow. It's a personal dashboard, like a step counter for Reddit participation. It gives people a
> glanceable view of their standing in the communities they care about without opening a browser, and it
> helps new members understand local karma requirements that many subreddits enforce.

**Provide a detailed description of what the Bot/App will be doing on the Reddit platform.**

> Krma is a native macOS application. Each user signs in to their own account through Reddit's OAuth2
> authorization-code flow for installed apps (no client secret; the user approves the app in their browser).
> It requests only the `identity` and `mysubreddits` scopes. On a timer (default every 5 minutes, minimum
> every minute) it calls exactly two endpoints: `GET /api/v1/me` for karma totals and `GET /api/v1/me/karma`
> for the per-subreddit breakdown, plus `GET /subreddits/mine/subscriber` every 30 minutes so the user can
> pick subreddits to follow. It never posts, comments, votes, messages, reads other users' data, or reads
> subreddit content. All history is stored locally on the user's Mac; nothing is sent to any server other
> than reddit.com, and there is no analytics or telemetry. It sends the documented User-Agent format
> (`macos:io.github.mrte1122.Krma:v<version> (by /u/<username>)`) and respects the X-Ratelimit headers.
> It is non-commercial: free, no ads, no paywall, no data resale, source on GitHub.

**What is missing from Devvit that prevents building on that platform?**

> Devvit apps run inside Reddit (on Reddit's servers and inside the Reddit UI). Krma is a desktop application
> that lives in the macOS menu bar and must call the Data API from the user's own computer with the user's
> own OAuth token. Devvit has no way to run code on a user's Mac, to issue per-user OAuth tokens to a native
> client, or to expose an external per-user endpoint a desktop app could poll, so the app cannot be built on
> it. The need is a single installed-app OAuth client ID (type "installed app", redirect URI `krma://oauth`).

## After approval

1. Create the app at https://www.reddit.com/prefs/apps: type **installed app**, redirect URI exactly
   `krma://oauth`, name `Krma`.
2. Copy the client ID shown under the app's name.
3. Paste it into Krma's sign-in card (or Settings → Account), or compile it into `RedditAuth.defaultClientID`
   in `Sources/Krma/RedditSignIn.swift` before publishing so other users don't need their own.

## Other rules worth knowing

- 100 requests per minute per client ID, averaged over 10 minutes. Krma uses about 2 per 5 minutes.
- Content deleted on Reddit must be deleted from the app within 48 hours. Krma stores only the user's own
  karma numbers and subreddit names, never posts or comments.
- Commercial use (ads, paywalls, subscriptions, paid features) needs a separate written agreement. Krma is
  free with no monetization of any kind; the tip link it once had was removed on 2026-10-25.
