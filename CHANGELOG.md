# Changelog

## 1.5.0 - login emails, 8 accounts

- Plan and login email under each account name in the popover, the floating panel and the setup window (Claude: `.claude.json`; Codex: `account/read` in the existing app-server session). Kept in memory only, never written, logged or sent; the widget is unchanged.
- "Hide Emails" in the icon menu and on the setup window's Finish step masks emails as `d•••@example.com`.
- Warning when two accounts of the same type are signed into the same login, with a Fix that opens the login Terminal flow for the account with its own login folder (never the default login; the later one when both have their own folders).
- Up to 8 accounts, including several Codex logins with separate `CODEX_HOME` folders (`home` in `accounts.json`, "Add Codex account" in the setup window, `.codex-*` folders suggested).
- The popover and the floating panel scroll inside the visible screen height; denser blocks above 4 accounts. Large widget: one row per account above 4; medium widget: a two-column grid above 4.
- Reorder accounts in the setup window.
- Claude checks stretch their cadence with many accounts (8 accounts: about every 2.5 minutes) so the sequential checks never run back to back.
- `AI_LIMITS_DATA_DIR` moves the app's data folder for isolated test runs, with separate preferences; an invalid value stops the app instead of using the real folder.
- Fixes: a saved account list is no longer lost when it arrives during another reload; a check that finishes after its folder changed is discarded; a `.claude.json` caught mid-write keeps the last plan, email and payment date; the height cap follows the display the popover or panel is on; the medium widget grid marks delayed data; a slow or interrupted `/usage` read counts as a failed check, not "Not signed in"; copied login commands expand `~` in zsh and ignore a `CLAUDE_CONFIG_DIR` / `CODEX_HOME` from the shell profile for default logins; queued Claude cards say they are waiting; at most two Codex app-server checks run at the same time, the rest wait for a free slot.

## 1.4.0 - onboarding

- First-run window that connects Claude and Codex accounts: live checks, one-click fixes in Terminal, extra Claude logins, widget and launch-at-login setup.
- "Fix" links next to failing accounts in the popover and panel.

## 1.3.0 - first public release

- Menu bar app and WidgetKit widget (medium and large) for Claude Code and Codex subscription limits: session, week and per-model weekly windows with reset times, for up to 4 accounts.
- Accounts are detected from the installed CLIs, or listed in `accounts.json` (several Claude logins via `configDir`, explicit CLI paths via `cli`), with live reload.
- Pace line and run-out forecast for every window.
- Next payment date: automatic for Claude, `billing.json` for other accounts.
- Token analytics from local Claude Code and Codex logs for today, 7 and 30 days, per provider and per model, with a cost estimate at public API prices and a 30-day bar chart.
- API prices: built-in table, automatic weekly update from the two public pricing pages, optional `prices.json` overrides.
- Floating panel, launch at login, English and Russian interface.
- Command line: `--self-test`, `--accounts`, `--check`, `--analytics`, `--prices`, `--update-prices`, `--launch-at-login`.
