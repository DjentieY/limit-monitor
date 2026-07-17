# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the app is macOS-only and reads reverse-engineered provider endpoints,
releases stay in the `0.x` range — expect occasional breakage when a provider
changes its API.

## [Unreleased]

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

[Unreleased]: https://github.com/DjentieY/limit-monitor/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/DjentieY/limit-monitor/releases/tag/v0.5.0
