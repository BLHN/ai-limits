# Changelog

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
