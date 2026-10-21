# PRWatcher

A macOS menu bar app that watches the open pull requests **you authored** on a chosen set of GitHub repos and alerts you when someone else comments, reviews, or pushes commits.

## Features

- Polls GitHub on an interval you choose (1–60 min, default 5) with a single GraphQL query.
- Alerts on new **comments** (conversation and inline), **reviews** and **commits** by other people. Your own activity is ignored. Draft PRs are excluded.
- Menu bar icon with an unread count, plus one native notification per PR per check. Clicking a notification opens the PR (or the exact comment/review/commit when there is only one).
- Popover with three tabs, grouped by repo: **Opened by me**, **Assigned to me** (open PRs by others that are assigned to you or waiting for your own review; PRs requested only through a team, and PRs you already reviewed, are not included) and **Other** (any PRs you add by link, see below). Columns:
  - **Status**: Open / Approved / Changes requested (Draft, Merged and Closed also show for PRs on the Other tab), plus the number of unresolved comment threads from other reviewers.
  - **Review**: the verdict dot from the latest GitHub Copilot review (🟢 approval recommended, 🟡 changes recommended, 🔵 needs a closer look) and its unresolved-thread count. Hover the dot to read the review text.
- PRs with new activity get a red dot and bold title. Opening the panel clears the menu bar count; the dots disappear the next time you open it.
- The first time a PR is seen, existing activity is recorded silently so you don't get a flood of alerts.
- Settings open inside the panel (no separate window), with a Back button.
- Optional launch at login.

## Requirements

- macOS 14+
- Xcode / Swift 5.9+ toolchain
- [GitHub CLI](https://cli.github.com) (`gh`), signed in with `gh auth login`. The app reads the token from `gh auth token`; nothing is stored by the app.

## Build and run

```sh
./build.sh          # builds PRWatcher.app (ad-hoc signed)
open PRWatcher.app
```

Notifications only work from the built `.app`, not from `swift run`. macOS asks for notification permission on first launch.

## Usage

1. Click the menu bar icon, then **Settings**. Settings opens inside the same panel; use **‹ Back** (or Esc) to return to the list.
2. Paste a repo as `owner/name` or a GitHub URL (for example `https://github.com/owner/repo`) and click **Add**.
3. Set the check interval. **Test GitHub token** confirms the `gh` login works.

**Other tab:** paste a PR link (for example `https://github.com/owner/repo/pull/123`, or `owner/repo#123`) and press **+**. Use the trash icon in the **Actions** column to remove a PR. A newly added PR shows "loading…" until it has been fetched. PRs on this tab are tracked and alert like your own, they don't need to be in a watched repo, and a PR that can't be read (deleted or no access) is listed as "not found or no access" so you can remove it. They stay in the list after they are merged or closed until you remove them.

Click a PR to open it on GitHub. Opening the panel marks everything as read.

## Development

```sh
swift build
swift test
```

| Path | Purpose |
| --- | --- |
| `Sources/PRWatcherCore` | Logic: GitHub client and parsing, unread tracking, store, notification grouping |
| `Sources/PRWatcher` | SwiftUI app: menu bar, popover, settings, notifier |
| `Tests/PRWatcherCoreTests` | Unit tests (mocked network, fake notifier) |
| `Tools/make-icon.swift` | Regenerates `Resources/AppIcon.icns` |

State is stored in `~/Library/Application Support/PRWatcher/state.json`; settings live in `UserDefaults`.

## Notes

- Copilot's own review summary and comments are not listed as activity; they appear only in the Review column.
- The app is only ad-hoc signed (`build.sh`), so on another Mac build it locally with `./build.sh` or right-click → Open the first time.
- Only the latest 30 comments/reviews/commits and 50 comment threads per PR are read.
