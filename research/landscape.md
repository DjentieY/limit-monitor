# limit-monitor — research memo: ландшафт, вердикт, источники данных, архитектура, дистрибуция

Дата: 2026-07-16. Синтез 4 scout-отчётов (landscape / Cursor / Codex / xplat-install) + инспекция текущего репо (`macos/SPEC.md`, `macos/Sources/`).

**Наш целевой набор фич** (из `macos/SPEC.md` + план владельца):

- F1 — tray/menu bar с цветными точками per-limit (`●10% 5h·●23% 7d·●39% Fable`)
- F2 — Claude: `GET https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`), креды из Keychain / `~/.claude/.credentials.json`, строго read-only, без OAuth refresh
- F3 — динамический `limits[]` incl. неизвестные kind / промо-скоупы (Fable) без изменений кода
- F4 — push-уведомление на сброс окна (пре-скедул на `resets_at + 5 s`)
- F5 — push на 100% исчерпание с дедупом между поллами и рестартами
- F6 — кросс-OS: macOS / Windows / Linux
- F7 — адаптер Cursor; F8 — адаптер Codex
- F9 — установка в одну строку per OS
- F10 — README-блок «вставь в своего агента» + `llms-install.md`

---

## 1. Ландшафт существующих инструментов

### 1.1 Таблица (актуальность проверена 2026-07-16)

| Инструмент | OS (tray) | Провайдеры | Источник данных | Reset / 100% push | Установка | Статус |
|---|---|---|---|---|---|---|
| [CodexBar](https://github.com/steipete/CodexBar) (steipete) | macOS 14+ (CLI ещё Linux/AUR) | 59+ incl. **Claude+Cursor+Codex** | цепочки стратегий: OAuth usage API, cookies, `codex app-server`, PTY, JSONL ([docs/](https://github.com/steipete/CodexBar/blob/main/docs/codex.md)) | thresholds + reset: да / 100%: не заявлено | `brew install --cask codexbar` | **18.5k★**, v0.43.0 (2026-07-14), очень активен |
| [openusage](https://github.com/robinebers/openusage) | macOS | 10 incl. Claude+Cursor | локальные креды + внутренние endpoints; local HTTP API `127.0.0.1:6736` | не документировано | Releases | 3.4k★, v0.7.6 (2026-07-16) |
| [ClaudeBar](https://github.com/tddworks/ClaudeBar) | macOS | 10 (Claude, Codex, Gemini, Copilot…) | per-CLI креды (механизм не документирован) | warning/critical: да; reset: нет | `brew install --cask claudebar` | 1,324★, v0.4.72 (2026-07-15) |
| [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) | macOS 14+ | Claude | Keychain OAuth; **v3.2.0 принял новый `limits[]` incl. Fable** | custom thresholds + звук: да; reset push: нет (только countdown-таймеры) | `brew install --cask claude-usage-tracker`, Nix | **3,047★**, v3.2.0 (2026-07-12) |
| [Usage4Claude](https://github.com/f-is-h/Usage4Claude) | macOS | Claude + Codex | claude.ai **web session key** (не CC OAuth) | **reset: да** + 90%; per-limit кольца в menu bar | dmg (без brew) | 337★, v3.3.0 (2026-07-14) |
| [Claude God](https://github.com/Lcharvol/Claude-God) | macOS 13+ | Claude | **ровно наш endpoint+header**, токен из `claude login` | **reset: да** + thresholds; промо-скоупы не документированы | brew tap + cask | 71★, v2.23.4 |
| [CCSeva](https://github.com/Iamshankhadeep/ccseva) | macOS | Claude | JSONL + OAuth-fallback | 70/90%: да; reset: нет | dmg | 800★; кросс-платформенность не случилась — форки [ccseva-windows](https://github.com/digitaladaption/ccseva-windows) / [ccseva-linux](https://github.com/crash2burn/ccseva-linux) |
| [claude-quota](https://github.com/grzegorz-raczek-unit8/claude-quota) (SwiftBar) | macOS | Claude | Keychain OAuth, тот же usage endpoint, per-model окна | нет уведомлений | curl one-liner | 69★ |
| [usage-monitor-for-claude](https://github.com/jens-duttke/usage-monitor-for-claude) (jens-duttke) | **Windows only** | Claude | `.credentials.json` OAuth; **динамические bucket'ы incl. Fable/Cowork, future-proof** | **reset: да** + thresholds + pace | portable EXE | 193★, v1.19.0 (2026-07-14), пуш сегодня |
| [claude-usage-widget](https://github.com/SlavomirDurej/claude-usage-widget) | Win/mac/Linux (desktop widget, не tray) | Claude | claude.ai usage | не документировано | Releases | 263★ (2026-07-13) |
| [ccusage](https://github.com/ryoppippi/ccusage) | терминал/statusline | Claude (+`ccusage codex`) | JSONL + OAuth limits | нет | npx/bunx | **17,212★** |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | терминал | Claude | statusline `rate_limits` + локальные оценки | нет | PyPI/uv | 8,454★ |
| [cursor-stats](https://github.com/Dwtexe/cursor-stats) | Cursor status-bar ext | Cursor | `state.vscdb` + cursor.com | — | ext | 263★, **ARCHIVED 2026-03-08** («constant Cursor pricing changes») |
| [CursorMeter](https://github.com/WoojinAhn/CursorMeter) | macOS | Cursor | недокум. usage/auth endpoints | thresholds 80/90 + reset-дата | Releases | 3★, v0.7.1 |
| [codex-cli-usage](https://pypi.org/project/codex-cli-usage/) | терминал | Codex | app-server RPC → REST fallback | — | PyPI | v0.1.8 (2026-07-16) |
| [codex-lb](https://github.com/Soju06/codex-lb) | proxy+dashboard | Codex | reimplements `/backend-api/codex/*` | — | — | 2.4k★, v1.21.0 |

Длинный хвост (не влияет на решение): ClaudeUsageBar (265★, session cookie), bishojbk/claude-usage (rate-limit headers через 1-token Haiku), Raycast ccusage (~11k installs), SessionWatcher (paid), claudeusagewin, utajum/claude-usage, Tendo33/cursor-usage-tracker, YossiSaadi ext, MacSteini/Codex-Usage (93★), en4ble1337 PTY-scraper.

### 1.2 Gap-анализ против наших фич

| Фича | Лучшее существующее покрытие | Дыра |
|---|---|---|
| F1 точки per-limit | Usage4Claude (кольца), claude-quota (gauges), наш Swift-app | покрыто конкурентами |
| F2 OAuth `/api/oauth/usage` | Claude God (идентично), claude-quota, Claude Usage Tracker | покрыто |
| F3 динамический `limits[]` + Fable | **только** Claude Usage Tracker v3.2.0 (macOS, добавлено 4 дня назад), jens-duttke (Windows), Chrome-расширение | на macOS 1 конкурент, сходимся |
| F4 reset push | Usage4Claude, Claude God, jens-duttke, CodexBar | покрыто частично (никто — для промо-bucket'ов) |
| F5 100% push с именем лимита | **никто не заявляет явно**; ближайшее — custom thresholds | открыто |
| F6 tri-OS tray | **НИКТО.** CodexBar tray = macOS-only; jens-duttke = Windows-only и Claude-only; Linux tray — пусто | **главная дыра ниши** |
| F7+F8 Claude+Cursor+Codex в одном tray | CodexBar (macOS), частично ClaudeBar | закрыто на macOS, открыто на Win/Linux |
| F9 one-line install per OS | brew cask'и / dmg; `curl\|sh` только у SwiftBar-плагинов | открыто (а cask для unsigned умирает, §5) |
| F10 agent-install блок | **НИКТО** (README CodexBar проверен — блока нет); паттерн есть у [beads](https://github.com/steveyegge/beads) и `llms-install.md` (Cline-конвенция) | открыто |

---

## 2. Вердикт: строить или взять готовое (честно)

**Для личной потребности «видеть лимиты Claude на macOS» строить было не нужно.** CodexBar (18.5k★, все три наших провайдера, активные релизы), openusage (3.4k★) или Claude Usage Tracker (3k★, `limits[]` c Fable) закрывают ~90–95% ценности установкой одной brew-командой. Ниша перенасыщена, сильнейшие инкамбенты релизятся еженедельно и сходятся к нашему набору фич (CUT добавил Fable-`limits[]` 4 дня назад).

**Но целевой продукт из плана — не «ещё один macOS-монитор».** Незанятая комбинация, которой нет ни у кого:

1. **tri-OS tray** с одинаковой семантикой (CodexBar tray принципиально macOS-native Swift; на Windows только Claude-only jens-duttke; на Linux — ничего);
2. **лёгкий CLI-first single binary** (`status --json` как quota-API для агентов и скриптов) vs 60-провайдерный комбайн;
3. **agent-native установка** (F10) — проверенно отсутствует у всех, при этом наша аудитория по определению сидит в Claude Code/Cursor/Codex;
4. reset **и** exhaustion push с точной семантикой (F4+F5) единые на всех OS.

**Рекомендация: строить, но узко.** Три провайдера максимум, без гонки с CodexBar по ширине. Честные риски: (а) steipete может выкатить Windows/Linux и закрыть дыру; (б) Cursor-адаптер = вечная поддержка (см. §3.1: cursor-stats с 263★ заархивирован именно из-за churn); (в) upside публичного репо ограничен — ниша уже поделена на macOS. Если не готовы к (б) — скоуп v1 = Claude+Codex (оба источника стабильнее), Cursor как experimental. Уже написанный Swift-app (`macos/`) остаётся ценным в любом сценарии — он почти готов и становится macOS-шеллом (§4).

---

## 3. Источники данных: Cursor и Codex

### 3.1 Cursor

Официального API для индивидуального пользователя **нет** (официальный — только [Admin API](https://cursor.com/docs/api) для Team/Enterprise, ключи `admin:*`). Все работающие тулы используют внутренние endpoints.

**Recipe A — рекомендуемый: `state.vscdb` → cookie → cursor.com.**
Уверенность: **механизм — высокая** (6+ независимых реализаций: [CodexBar docs/cursor.md](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md), [Tendo33/cursor-usage-tracker](https://github.com/Tendo33/cursor-usage-tracker), [YossiSaadi](https://github.com/YossiSaadi/cursor-usage-vscode-extension), [PyPI cursor-usage](https://pypi.org/project/cursor-usage/), openusage); **стабильность во времени — низкая** (endpoint churn задокументирован; точный JSON `usage-summary` нигде не опубликован — снять живьём).

1. Прочитать SQLite `ItemTable`:
   - macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
   - Windows: `%APPDATA%\Cursor\User\globalStorage\state.vscdb`
   - Linux: `~/.config/Cursor/User/globalStorage/state.vscdb`
   - `SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'` (рядом `cursorAuth/refreshToken`). WAL-режим: обычно читается без лока; при локе — copy-then-read.
2. `userId` — из JWT-клейма `sub` accessToken'а (или `GET /api/auth/me`). Собрать cookie:
   `WorkosCursorSessionToken=<userId>%3A%3A<accessToken>` (т.е. `userId::accessToken`).
3. Endpoints на `cursor.com` (cookie-auth):
   - `GET /api/auth/me` — identity;
   - `GET /api/usage?user=<userId>` — legacy per-model `numRequests/maxRequestUsage` + `startOfMonth` (якорь сброса цикла); на кредитной модели 2026 всё более вестигиален;
   - `GET /api/usage-summary` — план/included usage, on-demand, окно биллинг-цикла (**USD-точный**; JSON снять живьём);
   - `GET /api/auth/stripe` — план (Pro/Pro+/Ultra/Team), статус, конец цикла;
   - `POST /api/dashboard/get-current-period-usage` — кредитный пул в USD, но **интермиттентные 400** — только как best-effort.

**Recipe B — `api2.cursor.sh` c Bearer: избегать.** Уверенность: низкая. Требует reverse-engineered `x-cursor-checksum` + машинные заголовки ([eisbaw/cursor_api_demo](https://github.com/eisbaw/cursor_api_demo)) — version-sensitive, выглядит как abuse.

**Recipe C — официальный Admin API: только Enterprise/Team.** Уверенность: высокая, но соло-Pro неприменимо (ключ может выпустить только админ команды).

**Семантика (критично для точек):** с июня 2025 Cursor — **USD-кредитный пул** (Pro $20 / Pro+ $60 / Ultra $200 included в месяц), сброс по **дате биллинга**, не календарю. Auto-режим — unlimited и пул не тратит; ручной выбор frontier-моделей тратит. Два независимых потолка: (1) пул/спенд — наше «100% исчерпание»; (2) throughput-лимит (очередь при пике) — чистым числом не отдаётся, точкой не показать. **Аналога 5h-окна и промо-скоупов нет** → у Cursor 1–2 точки: `pool $used/$limit` (+ on-demand spend), reset-notification по концу цикла из `stripe`/`usage-summary`.

**Риски:** endpoint churn (архив cursor-stats — прецедент); `accessToken` — JWT с истечением: **re-read `state.vscdb`** (Cursor сам обновляет), self-refresh через `api2.cursor.sh/oauth/token` — только opt-in; токен = **полный аккаунт** (чат, биллинг) — только Keychain/секрет-хранилище, никогда не логировать; edge-cases определения плана (legacy Team → «No active subscription», [openusage#244](https://github.com/robinebers/openusage/issues/244)). Полл — редкий, ~300 s (stale-while-revalidate, как openusage).

### 3.2 Codex

Keychain нет — всё в plaintext `~/.codex/auth.json` (или `$CODEX_HOME/auth.json`): `tokens: {access_token, refresh_token, id_token, account_id}`; структура **официально документирована** ([developers.openai.com/codex/auth/ci-cd-auth](https://developers.openai.com/codex/auth/ci-cd-auth)); `id_token` содержит клейм `chatgpt_plan_type` (лейбл плана).

**Recipe A — REST (primary).** Уверенность: **высокая** — это то, что сам Codex TUI делает каждые ~60 s ([openai/codex#10869](https://github.com/openai/codex/issues/10869) → PR #10973); воспроизведено CodexBar, ccusage, MacSteini и др. Стабильность: средняя — идёт миграция namespace `wham` → `codex`.

```
GET https://chatgpt.com/backend-api/wham/usage        # fallback: /backend-api/codex/usage
Authorization: Bearer <tokens.access_token>
ChatGPT-Account-Id: <tokens.account_id>
Accept: application/json
Origin: https://chatgpt.com  (+ Referer, браузероподобный User-Agent — иначе риск WAF)
```

Ответ: `rate_limit.primary_window` (5h, `window_minutes≈299`) и `secondary_window` (weekly, `≈10079`) + `additional_rate_limits[]` — скоуп-лимиты per-model/code-review (структурный аналог Fable). **Нормализовать алиасы полей**: `used_percent|percent_left`, `resets_in_seconds|reset_at|reset_time_ms`. 401 = истёк access token (~часовой), 403 = WAF/аккаунт. Бонус: `GET .../wham/rate-limit-reset-credits` — баланс reset-кредитов (у Claude аналога нет). **Никогда не рефрешить токен самим**: refresh-токены ротируются, чужой refresh инвалидирует токен самого codex → форс-релогин ([9router#1663](https://github.com/decolua/9router/issues/1663)); `client_id` известен публично, но использовать нельзя. Полл ≥60 s.

**Recipe B — `codex app-server` JSON-RPC (fallback).** Уверенность: **высокая, полу-официальная** ([docs](https://developers.openai.com/codex/app-server)) — санкционированная интеграционная поверхность, это primary-источник codex-cli-usage. `codex app-server` (stdio) → handshake `initialize` → метод `account/rateLimits/read` → `{primary, secondary}` каждый `{usedPercent, windowMinutes, resetsAt}` + `rateLimitResetCredits` (PR [#28143](https://github.com/openai/codex/pull/28143)). Плюс: auth/refresh делает сам codex — ноль работы с кредами и ноль ToS-рисков. Минус: нужен установленный залогиненный codex, управление child-process, schema drift (снимать `codex app-server generate-json-schema`).

**Recipe C — sessions JSONL (offline last-known).** Уверенность: высокая достоверность данных, но **stale при простое**. `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, event `token_count` несёт `rate_limits`-снапшот (источник — заголовки `x-codex-*-used-percent`). Формат внутренний, дрейфует.

**Recipe D — PTY-scrape `/status`: не делать** (низкая; headless `codex usage --json` не существует, [#15281](https://github.com/openai/codex/issues/15281) открыт).

**Рекомендуемый порядок: A → B → C** — ровно стек CodexBar и codex-cli-usage.

### 3.3 Нормализация (единая модель для всех шеллов)

```go
type Limit struct {
    Provider string     // "claude" | "cursor" | "codex"
    Kind     string     // "session" | "weekly_all" | "weekly_scoped" | "pool" | unknown-passthrough
    Label    string     // "5h" | "7d" | "Fable" | "$20 pool" | ...
    Percent  int        // 0..100+
    ResetsAt *time.Time // nullable
    Severity string
}
// события state machine: reset(limit), exhausted(limit) — семантика 1:1 из ClaudeLimitsCore.plan()
```

Маппинг: Claude `limits[]` → как есть (unknown kinds рендерить generически — уже в SPEC); Codex `primary/secondary/additional[]` → `session/weekly_all/scoped`; Cursor → `pool` (+ `on_demand`), reset = конец биллинг-цикла.

---

## 4. Архитектура репозитория

**Принцип: shared core + тонкие шеллы.** Доказательства: CodexBar = core, потребляемый и menu-bar-приложением, и CLI; контрпример — ccseva: «кросс-платформенный» Electron дал macOS-only приложение и два чужих форка под Win/Linux. Electron отвергнут (150–180 MB под точку в трее), Tauri отвергнут (webkit2gtk-зависимость на Linux ради UI, которого у нас нет).

**Язык core — Go.** Причины: [fyne-io/systray](https://github.com/fyne-io/systray) (Win: win32; Linux: чистый DBus SNI без GTK; macOS: cgo), [beeep](https://github.com/gen2brain/beeep) (уведомления: osascript / WinRT-PowerShell / DBus), GoReleaser (весь §5 из одного конфига), статические бинари 5–15 MB. Rust (`tray-icon`+`notify-rust`+cargo-dist) равнозначен, но Go-связка зрелее (у winrt-notification тост от имени «PowerShell», ksni ещё вливается в tauri). Swift кросс-платформенно не тянет tray на Windows.

```
limit-monitor/
  core/            # Go: providers/{claude,cursor,codex}/, model.go, statemachine.go (reset/exhausted+dedup),
                   #     CLI: status --json | watch --json (NDJSON) | swiftbar | autostart enable|disable | notify-test
                   #     tray_{windows,linux}.go (build tags, fyne-io/systray) + notify (beeep-style)
  macos/           # СУЩЕСТВУЮЩИЙ Swift SPM app — премиальный macOS-шелл (см. ниже)
  fixtures/        # захваченные ответы API (usage_sample.json + cursor/ + codex/) — общие для Swift checks и Go tests
  install/         # install.sh, install.ps1
  llms-install.md
  README.md
```

**Куда встаёт текущий `macos/`.** Он остаётся и не переписывается: `ClaudeLimitsCore` (чистая логика: парсинг `limits[]`, уровни green/yellow/orange/red, планировщик уведомлений `plan(limits:now:alreadyNotified:)`) + `claude-limits` (NSStatusItem, attributed-title с цветными точками, `UNUserNotificationCenter`, `SMAppService`, `--check`). Эволюция в два шага:

1. **Сейчас (P1):** app реализован полностью по SPEC (Core: 9 файлов, executable, `checks`, `--check` e2e) и собран: `scripts/make_app.sh` делает `swift build -c release` → `build/Claude Limits.app` (LSUIElement, ad-hoc codesign) → `--install` в `~/Applications`. Остаток P1 — не код, а дистрибуция: repo-root `install.sh`, README с agent-блоком, публикация.
2. **После появления Go core (P3):** Swift-app переключает источник данных с собственного fetch на `limit-monitor watch --json` (subprocess, NDJSON) — и **бесплатно получает Cursor/Codex-точки**, сохраняя нативные преимущества: настоящие `UNUserNotificationCenter`-уведомления (требуют .app-бандл — у Go-трея на macOS с этим плохо), `SMAppService`-логин-айтем, качество NSStatusItem. `ClaudeLimitsCore.plan()` — референс-спека для портирования state machine в Go; общие `fixtures/` гарантируют паритет парсинга.

**Фазы:** P1 — Swift app (готов) + `install.sh` + agent-блок в README + публикация (уже продукт, Claude-only macOS). P2 — Go core с Claude-адаптером (паритет на тех же fixtures) + tray Windows/Linux + `install.ps1`. P3 — адаптеры Codex, затем Cursor (experimental); Swift-шелл переходит на core; brew formula для CLI. При публикации имя унифицировать: bundle сейчас называется `Claude Limits.app` — переименовать в `Limit Monitor.app`/`limit-monitor`, когда репо станет мульти-провайдерным (agent-блок в §6 уже использует целевое имя).

**Бонус-дифференциатор:** `limit-monitor status --json` — это quota-API для самих агентов (pre-flight перед длинным автономным прогоном: «сколько недельного лимита осталось»); у openusage аналог — local HTTP API на `127.0.0.1:6736`.

**Задокументировать в репо (грабли инкамбентов):** Keychain-ACL слетает, когда Claude Code перезаписывает item → повторные промпты ([CodexBar#624](https://github.com/steipete/CodexBar/issues/624), [#485](https://github.com/steipete/CodexBar/issues/485)) — у нас чтение через `/usr/bin/security` subprocess (на машине владельца verified тихое, но на чужих возможен промпт; фолбэк `~/.claude/.credentials.json`); дрейф схемы keychain-item (только `mcpOAuth`-записи, [#1844](https://github.com/steipete/CodexBar/issues/1844)) — парсить толерантно; **никогда не рефрешить чужие OAuth-токены** ([#1161](https://github.com/steipete/CodexBar/issues/1161), 9router#1663).

---

## 5. Установка в одну строку per OS

Паттерн SOTA (uv, bun, beads): `curl -fsSL …/install.sh | sh` + `irm …/install.ps1 | iex`; генерится GoReleaser'ом (для Go) или cargo-dist.

**macOS — ключевой факт: `curl`/`scp` НЕ ставят `com.apple.quarantine`, поэтому Gatekeeper вообще не вызывается** — документированное Apple поведение ([Apple Community](https://discussions.apple.com/thread/256200611), [Unit42](https://unit42.paloaltonetworks.com/gatekeeper-bypass-macos/)). Реальность для unsigned-приложений:

- Sequoia убрал right-click-bypass ([mjtsai](https://mjtsai.com/blog/2024/07/05/sequoia-removes-gatekeeper-contextual-menu-override/)): скачанный браузером unsigned `.app` = поход в System Settings → «Open Anyway». Значит браузерная загрузка — плохой путь; **one-liner — единственный хороший**.
- **Homebrew cask закрывается для unsigned: с 2026-09-01** Homebrew 5 прекращает поддержку cask'ов, не проходящих Gatekeeper ([brew#20755](https://github.com/Homebrew/brew/issues/20755)). Cask ⇒ нужен Developer ID + notarization ($99/год). CLI-**formula** не затронута — путь для core.
- `install.sh` делает: fetch per-arch tarball → локальная сборка `.app` (Info.plist: `LSUIElement=true`, `CFBundleIdentifier=com.vladlaiho.claude-limits`) → `codesign -s -` (**ad-hoc обязателен на arm64**) → в `~/Applications` → login item через `SMAppService` из самого приложения (уже в SPEC). Кварантина не появляется ни на одном шаге.
- Уведомления: `UNUserNotificationCenter` требует `.app`-бандл (краш вне бандла — guard уже в SPEC) и TCC-разрешение привязано к code-sign identity → **при ad-hoc каждый апдейт = новая identity = пере-запрос разрешения на уведомления**. Мириться и документировать; Developer ID — только если появится аудитория GUI-загрузок. (Go-core на macOS при standalone-использовании шлёт через `osascript` — beeep-путь, без бандла.)

**Windows:** `irm https://…/install.ps1 | iex` — скрипт исполняется in-memory (**нет MOTW**), `curl.exe`/`iwr` скачанный бинарь тоже без MOTW ([ASEC](https://asec.ahnlab.com/en/87091/)) → SmartScreen «Unknown publisher» возникает **только** при браузерной загрузке ([пример](https://github.com/open-webui/desktop/issues/117)) — предупредить в README. Скрипт: бинарь в `%LOCALAPPDATA%\Programs\limit-monitor` → ярлык в Start Menu **с AUMID** (обязателен для настоящих тостов unpackaged-exe, [MS Learn](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/send-local-toast-other-apps)) → автостарт `HKCU\...\Run` (без админа). Позже: scoop (подписи не требует), winget.

**Linux:** `curl -fsSL …/install.sh | sh` → бинарь в `~/.local/bin` → `~/.config/autostart/limit-monitor.desktop` (XDG). Tray = StatusNotifierItem по DBus (fyne-systray, без GTK). **Обязательный caveat в README/llms-install: stock GNOME не показывает tray-иконки без [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/)** (Ubuntu предустанавливает, Fedora — нет); KDE/XFCE — ок. Уведомления `org.freedesktop.Notifications`/`notify-send` — беспроблемные.

**Релизная механика:** GoReleaser → GitHub Releases (архивы per OS/arch) + brew formula + scoop + AUR + nfpm deb/rpm; `install.sh`/`install.ps1` лежат в репо и линкуются через `releases/latest/download/…`.

---

## 6. Agent-install блок для README (драфт)

Обоснование паттерна: [beads](https://github.com/steveyegge/beads) (~18.7k★) онбордит агента прямо из README (`curl … | bash` + строка в AGENTS.md); конвенция `llms-install.md` от Cline ([magic-mcp](https://github.com/21st-dev/magic-mcp/blob/main/llms-install.md), [microsoft/mcp](https://github.com/microsoft/mcp/blob/main/llms-install.md)); у CodexBar такого блока нет — проверено. `OWNER` заменить на реальный GitHub-логин при публикации.

~~~markdown
## Install with your AI coding agent

Paste this into Claude Code, Cursor, or Codex:

```
Install limit-monitor — a menu-bar/tray monitor for Claude / Cursor / Codex usage limits.

1. Detect my OS.
2. Install (no sudo/admin; user-level paths only):
   - macOS / Linux:
     curl -fsSL https://github.com/OWNER/limit-monitor/releases/latest/download/install.sh | sh
   - Windows (PowerShell):
     irm https://github.com/OWNER/limit-monitor/releases/latest/download/install.ps1 | iex
3. Verify: run `limit-monitor status --json`. Success = valid JSON with a non-empty "limits"
   array for at least one provider. On failure, fetch
   https://github.com/OWNER/limit-monitor/blob/main/llms-install.md and follow its
   troubleshooting tree (macOS Keychain prompt; Linux GNOME needs the AppIndicator
   extension; Windows SmartScreen only if you downloaded via a browser), then retry.
4. Enable autostart and launch:
   - macOS: `open -a "Limit Monitor"` (the installer already registered login-item support)
   - Windows/Linux: `limit-monitor autostart enable && limit-monitor tray &`
5. Report back to the user: which providers were detected and the current percentage and
   reset time of every limit.

Rules for you, the agent:
- The tool is READ-ONLY over existing local credentials (Claude Code Keychain item /
  ~/.claude/.credentials.json, ~/.codex/auth.json, Cursor state.vscdb). Never print, log,
  or transmit tokens. Never attempt to refresh any OAuth token.
- Use the one-liners above; do not download release binaries through a browser.
```

Optional, for agent workflows: let your agent budget itself —
`echo "Before long autonomous runs, check remaining quota: limit-monitor status --json" >> AGENTS.md`
~~~

Рядом с README шипается `llms-install.md` — полное дерево решений для агента: определение OS/arch → выбор one-liner'а → верификация → известные фейлы и их фиксы (Keychain-ACL промпт и фолбэк на `.credentials.json`; GNOME AppIndicator; SmartScreen/MOTW; истёкший токен → «открой Claude Code / codex»; для Cursor — «эндпоинты неофициальные, адаптер может деградировать») → как удалить. Заметьте зацепление с архитектурой: шаг «Verify» работает потому, что core CLI-first (`status --json`) — агент может доказать успех установки без GUI.

---

### Сводка решений

| Вопрос | Решение |
|---|---|
| Брать готовое? | Для себя-сегодня — CodexBar закрыл бы всё; строим только ради незанятой ниши tri-OS + agent-native (§2) |
| Cursor | Recipe A (`state.vscdb` → `WorkosCursorSessionToken` → cursor.com), experimental-статус, полл ~300 s |
| Codex | REST `wham/usage` → app-server RPC → JSONL; auth.json read-only, без self-refresh, полл ≥60 s |
| Архитектура | Go core (адаптеры+state machine+CLI+Win/Linux tray) + существующий Swift `macos/` как премиальный шелл поверх `watch --json` |
| Установка | `curl\|sh` (без кварантины, ad-hoc codesign, локальная сборка .app) + `irm\|iex` (без MOTW, AUMID-ярлык) + `curl\|sh` (XDG, GNOME-caveat); GoReleaser; brew только formula |
| Дифференциация | tri-OS + 100%-exhaustion push + `status --json` как quota-API агентов + agent-install блок |
