# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the app is macOS-only and reads reverse-engineered provider endpoints,
releases stay in the `0.x` range — expect occasional breakage when a provider
changes its API.

## [Unreleased]

## [0.7.0] - 2026-07-17

### Added

- **Configurable bar separators** — a *Separators* section in Settings lets you
  set the string between providers and between a provider's limits (with a live
  preview and a reset button); applied instantly.

### Changed

- The default between-provider separator is now `┃` (heavy vertical), giving a
  clearer thin/heavy hierarchy with the within-provider `│`.
- `providers.json` parse errors are now localized, so the English UI stays fully
  English even on a malformed config.

### Docs

- The install instructions moved above the feature list in the README.

## [0.6.0] - 2026-07-17

Internationalization: the UI is now **English by default** and switches to
Russian automatically on a Russian system.

### Added

- English localization of every user-facing surface — menu, notifications, the
  settings window, the desktop card and the `--status` table — selected by the
  system language (`Locale.preferredLanguages`); Russian is preserved verbatim.
- A code-based EN+RU string catalog in the core (compile-time complete; no
  resource bundles), with the language resolved once per process.

### Changed

- `--check` output is now always English (a stable, greppable diagnostic
  surface for CI and agents).
- **Widget snapshot schema is now v2** and fully neutral: the localized `label`
  field is gone; labels are reconstructed at read time from the neutral
  `kind` / `scopeName` / `windowMinutes` fields. External consumers
  (SwiftBar/agents) should key off those structural fields, not display text.
  A stale v1 snapshot is rejected and regenerated on the next poll.

### Notes

- A manual language picker in Settings is planned for a later release; malformed
  `providers.json` parse reasons are not yet localized.

## [0.5.0] - 2026-07-17

First tagged release. A macOS menu bar monitor for AI subscription rate limits
and balances. Consolidates the internal `v0.1`–`v0.5` milestones.

### Added

- **Claude** rate-limit windows (5-hour session, weekly, and scoped/promotional
  limits such as the current "Fable" weekly promo) read from the same
  `GET api.anthropic.com/api/oauth/usage` endpoint the official screen uses;
  colored per-limit dots; reset and exhaustion notifications, pre-scheduled so
  they fire on time even offline.
- **Codex** provider — reads `~/.codex/auth.json` and polls
  `chatgpt.com/backend-api/wham/usage` (alias-tolerant parser, endpoint
  fallback, browser-like headers).
- **Cursor** provider — session token read strictly read-only from Cursor's
  local `state.vscdb`, `cursor.com/api/usage-summary` split into Auto+Composer /
  API / on-demand buckets for the billing cycle.
- **Custom providers** via `~/.config/limit-monitor/providers.json`: built-in
  adapters for OpenRouter, DeepSeek, Moonshot (Kimi) and Zhipu (GLM), presets
  for SiliconFlow and Novita, and a generic HTTP-JSON balance adapter for any
  provider that exposes a balance or quota.
- **Settings window** («Настройки…», ⌘,) with a checkbox per provider to show
  or hide it live.
- **Desktop card** — a non-activating panel above the desktop icons (the
  ad-hoc-compatible "widget"; a real WidgetKit widget is blocked by the chronod
  identity gate under ad-hoc signing — recipe conserved in
  [`research/widget.md`](research/widget.md)).
- **Widget-ready snapshot** and `limit-monitor --status [--json]` — a
  network-free, machine-readable integration point for agents, SwiftBar, Raycast.
- One-line source installer and AI-coding-agent install instructions.

### Notes

- The app is ad-hoc signed and built from source, so it is never quarantined —
  no Gatekeeper friction, no paid certificate. It never refreshes or mutates any
  provider token.
- UI is currently Russian; English localization is in progress.

[Unreleased]: https://github.com/DjentieY/limit-monitor/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/DjentieY/limit-monitor/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/DjentieY/limit-monitor/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/DjentieY/limit-monitor/releases/tag/v0.5.0
