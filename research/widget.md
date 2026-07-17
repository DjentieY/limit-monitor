# WidgetKit без Xcode под ad-hoc подписью: вердикт и рецепт

Синтез двух независимых эмпирических экспериментов на целевой машине (macOS 26.5.2 Tahoe, arm64,
только Command Line Tools / Swift 6.3.3, Xcode отсутствует, `security find-identity`: 0 identities).
Дата: 2026-07-17.

## Вердикт

Двухчастный:

1. **Собрать WidgetKit .appex без Xcode — МОЖНО** (confidence: high, доказано локально дважды).
   Секрет Xcode-сборки — линкер-флаг `-e _NSExtensionMain` (вход через Foundation, а не Swift
   `_main`). Без него на macOS 26 `WidgetBundle.main()` возвращается и процесс умирает — ровно баг
   CodexBar #1095. С флагом бинарь по форме идентичен Xcode-каноничному (сверено вскрытием
   Stats.app: тот же `U _NSExtensionMain`), прямой запуск даёт каноничное "An XPC Service cannot
   be run directly.", pluginkit регистрирует appex ("+"), containermanagerd провизионирует
   sandbox-контейнер.

2. **Запустить его под ad-hoc подписью (`codesign -s -`) на macOS 26 — НЕЛЬЗЯ** (confidence:
   high). Гейт: chronod отказывается кэшировать дескрипторы расширений без Apple-issued подписи —
   verbatim из лога: "Requested to add extension, but purging instead because we shouldn't cache
   it: ... isApple? false". Воспроизведено на двух независимых тестовых бандлах
   (com.lmtest.host.widget и com.limitmonitor.demohost.widget — обе purge); позитивные контроли на
   той же машине — Stats (Developer ID + notarized, Descriptors Count: 6), Outlook, Happ —
   кэшируются. Подмешивание полного Xcode-метаданного набора (DT*, BuildMachineOSBuild) не
   помогает — гейт на identity, не на упаковке. Расширение ни разу не запускается и в галерею
   виджетов не попадает (галерея читает кэш дескрипторов chronod, который стоит выше по пайплайну).

Противоречия между экспериментами нет: первый остановился на успешной pluginkit-регистрации с
пометкой "последняя миля не проверена"; второй прошёл эту милю по логам chronod и закрыл вопрос
отрицательно. Прецедент CodexBar подтверждает картину: их SwiftPM-виджет сломался на 26.5
(#1095), фикс — настоящий Xcode-таргет (коммит 487a78ce) + релизы Developer ID + notarization;
их "adhoc"-режим доказан только до pluginkit, известен issue #533 "registered but never appears
in Widget Gallery".

**Итог для проекта:** WidgetKit-виджет под текущие констрейнты (ad-hoc, без Xcode) в v0.5 не
делаем. Рецепт ниже доказан до последнего гейта и консервируется: он становится рабочим в момент
появления Apple-issued identity. Разблокировки: Developer ID ($99/год, для распространения — +
notarization) либо бесплатный "Apple Development"-сертификат — но он выдаётся только через Xcode
automatic signing, т.е. двойное нарушение констрейнтов. Для v0.5 идём fallback-путём (см. план).

## Точный рецепт сборки (законсервирован; активен при identity)

### 1. Widget-таргет

SwiftPM (macos/Package.swift; сейчас в репо `.macOS(.v13)` — виджету нужен `.v14` из-за
`containerBackground(_:for:)` — поднять platforms или выделить виджет в отдельный пакет):

```swift
.executableTarget(
    name: "limit-monitor-widget",
    dependencies: ["LimitMonitorCore"],
    linkerSettings: [
        .linkedFramework("WidgetKit"),
        .linkedFramework("SwiftUI"),
        .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])  // КРИТИЧНО
    ]
)
```

Код — обычный `@main struct ...: WidgetBundle` + `TimelineProvider` + `StaticConfiguration`, без
main.swift и без dispatchMain. `unsafeFlags` легальны только в root-пакете (пакет нельзя будет
потреблять как зависимость — для app-репо неважно). Эквивалент на голом swiftc:

```
xcrun swiftc -O -parse-as-library -application-extension \
  -target arm64-apple-macos14.0 Widget.swift -o limit-monitor-widget \
  -framework WidgetKit -framework SwiftUI -framework Foundation \
  -Xlinker -e -Xlinker _NSExtensionMain
```

### 2. Раскладка бандла (в make_app.sh)

```
LimitMonitor.app/Contents/PlugIns/LimitMonitorWidget.appex/
  Contents/Info.plist
  Contents/MacOS/limit-monitor-widget
```

### 3. Info.plist виджета (канон из Stats.app / CodexBar / системного Calendar на 26.5)

```
CFBundleDevelopmentRegion      en
CFBundleDisplayName            LimitMonitor          (имя в галерее)
CFBundleExecutable             limit-monitor-widget
CFBundleIdentifier             <app-bundle-id>.widget   (префикс = id хоста)
CFBundleInfoDictionaryVersion  6.0
CFBundleName                   LimitMonitorWidget
CFBundlePackageType            XPC!
CFBundleShortVersionString     <версия приложения>
CFBundleVersion                1                     (бампать при debug-циклах)
CFBundleSupportedPlatforms     [MacOSX]
LSMinimumSystemVersion         14.0
NSExtension = { NSExtensionPointIdentifier = com.apple.widgetkit-extension }
```

Именно NSExtension-стиль в Contents/PlugIns/ (не ExtensionKit/Contents/Extensions/ — системные
виджеты на 26.5 всё ещё NSExtension). `NSExtensionPrincipalClass` НЕ указывать (даёт
"Unrecognized extension type"); DT*-ключи не обязательны (проверено: не влияют на гейт).

### 4. Entitlements виджета (widget.entitlements) — ОБЯЗАТЕЛЬНО

```xml
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array><string>/Library/Application Support/limit-monitor/</string></array>
</dict>
```

Sandbox обязателен (несандбоксные appex система не исполняет: "plug-ins must be sandboxed").
Формат пути: ведущий слэш и завершающий слэш у директории. App-group ключи НЕ добавлять без
настоящего сертификата (см. data sharing).

### 5. Подпись — строго изнутри наружу

```bash
codesign --force -s - --entitlements widget.entitlements "$APP/Contents/PlugIns/LimitMonitorWidget.appex"
codesign --force -s - "$APP"
# при identity: codesign --force --timestamp --options runtime -s "Developer ID Application: ..." ...
#               затем notarize + staple (иначе Gatekeeper на 15/26 блокирует скачанное)
```

### 6. Установка и регистрация

```bash
cp -R LimitMonitor.app /Applications/     # или ~/Applications; из /tmp discovery pkd капризен
open /Applications/LimitMonitor.app       # запуск хоста триггерит LS -> pkd discovery
# dev-принудительно:
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LimitMonitor.app
```

`pluginkit -a` сам по себе НЕ регистрирует и непостоянен — регистрация живёт от
LaunchServices-записи хост-приложения.

### 7. Верификация (включая go/no-go гейт)

```bash
nm <binary> | grep NSExtensionMain     # должно быть 'U _NSExtensionMain'
"$APPEX/Contents/MacOS/limit-monitor-widget"
#   ожидаем: 'An XPC Service cannot be run directly.' (правильный вход)
#   'Unrecognized extension type' / тихий выход = потерян флаг -e (= баг CodexBar #1095)
pluginkit -m -v -p com.apple.widgetkit-extension | grep <widget-bundle-id>
# GO/NO-GO (главный чек):
log show --last 5m --predicate 'process == "chronod"' | grep -i purg
#   'purging instead ... isApple? false' -> гейт сработал, виджета не будет
# галерея не обновилась: killall chronod NotificationCenter Dock; killall -9 pkd
```

### 8. Обновление таймлайна

После каждого поллинга главное приложение атомарно пишет snapshot-JSON и зовёт
`WidgetCenter.shared.reloadAllTimelines()` (хосту добавить `.linkedFramework("WidgetKit")`).
Виджет в getTimeline только читает и рендерит JSON — никакой сети и никаких ключей в
sandboxed-процессе. Системный бюджет ~40-70 обновлений/день — в таймлайн закладывать будущие
состояния заранее (reset-времена); "каждые 5 минут" виджету не гарантируется.

## Data sharing: решение

**Выбрано: snapshot-JSON файл + temporary-exception read-only.** Несандбоксный хост пишет
`~/Library/Application Support/limit-monitor/widget-snapshot.json` (каталог уже является данными
приложения; имя НЕ reverse-DNS — не попадает под TCC-эвристику Sonoma+ "данные других приложений");
сандбоксный виджет читает его через entitlement из шага 4. Работает с любой подписью, профиль не
нужен, для не-App-Store дистрибуции легально. Запись — во временный файл + rename (atomic). В
снапшоте только числа/проценты/reset-времена — НИКАКИХ ключей (sandbox всё равно не исполнит
shell-источники ключей; совпадает с политикой "tokens never logged").

Эскиз формата (widget-ready, полезен и фолбэкам — CLI/SwiftBar):

```json
{ "version": 1, "generatedAt": "2026-07-17T09:00:00Z", "providers": [
  { "id": "claude", "label": "CL", "mode": "percent", "percentLeft": 63,
    "valueText": "63%", "level": "ok", "resetAt": "2026-07-17T13:00:00Z" },
  { "id": "deepseek", "label": "DS", "mode": "balance", "valueText": "$23.45", "level": "warn" } ] }
```

Отвергнутые каналы (с доказательствами):

- **App Groups** — под ad-hoc мертвы: containermanagerd на macOS 26 отклоняет группы без
  TeamID-префикса ("Requestor's signature does not allow it to access a TCC-protected group
  container. Group containers identifiers should be prefixed by requestor's team ID" — CodexBar
  #533/#121, далее chronod NSCocoaErrorDomain 4099), а team ID существует только у Apple-issued
  сертификатов (Quinn/DTS, thread 776087). При настоящем сертификате — использовать macOS-стиль
  `TEAMID.slug` (так у Stats: RP2S87B72W.eu.exelban.Stats.widgets и CodexBar:
  Y5PE65HELJ.com.steipete.codexbar); iOS-стиль `group.*` без профиля даёт reject/промпт.
- **Запись хостом в контейнер виджета** (~/Library/Containers/<widget-id>/...) — Sonoma+ защищает
  чужие контейнеры TCC-промптом "access data from other apps"; у ad-hoc identity = cdhash, промпт
  возвращается после КАЖДОЙ пересборки.
- **UserDefaults(suiteName:)** — без app group суита недоступна сандбокс-виджету; исключение
  shared-preference существует, но файл проще и прозрачнее.
- **XPC** — нужны mach-lookup exception + launchd MachService; противоречит короткоживущей
  timeline-модели WidgetKit. Отвергнуть.
- **Сеть из самого виджета** — дублирует fetch-логику и упирается в недоступность конфига с
  ключами из сандбокса. Отвергнуть.

## Риски и митигации

| Риск | Митигация |
|---|---|
| chronod-политика кэширования недокументирована, выведена корреляцией (2 ad-hoc purge / 3 signed cached); может измениться в любом минорном апдейте | после каждого апдейта ОС — smoke-чек шага 7 (лог chronod); рецепт живёт в репо |
| точный предикат гейта не дизассемблирован: возможно, требуется notarization, а не просто identity | при первой подписанной сборке сначала прогнать go/no-go чек, потом вкладываться в UI |
| macOS 14/15 живьём не проверены (у CodexBar там работал SwiftPM-виджет, но с настоящей подписью) | не обещать пользователям; единственный источник правды — гейт-чек на месте |
| sandbox обязателен для appex -> внутри виджета нет ~/.config, env и shell-команд | вся добыча данных в хосте; виджет читает только снапшот |
| unsafeFlags ломает потребление пакета как зависимости | ок только в root-пакете приложения |
| платформа пакета .v13, виджету нужен .v14 | поднять platforms или отдельный пакет |
| App-group entitlements из туториалов (group.*) | не копировать; только TEAMID.slug и только с настоящим сертификатом |
| pluginkit -a непостоянен; discovery вне /Applications капризен | установка в /Applications или ~/Applications + одноразовый запуск хоста; lsregister -f в dev |
| бюджет обновлений WidgetKit ~40-70/день | таймлайн с заранее заложенными будущими состояниями + reloadAllTimelines() после поллинга |
| TCC-промпты при касании чужих контейнеров; cdhash-identity -> промпт после каждой пересборки | не трогать контейнер виджета; писать только в свой каталог limit-monitor |
| NSPanel-фолбэк: мельтешение в Mission Control/Spaces при неверном level/collectionBehavior | .nonactivating; level между desktop и normal; canJoinAllSpaces + stationary |
| killall chronod/NotificationCenter перезапускает виджеты пользователя | только в dev-инструкциях, не в install.sh |
| ре-подпись хоста ломает подпись appex | в make_app.sh/install.sh подписывать строго изнутри наружу |
| Apple может перевести widget-appex на ExtensionKit-раскладку (Contents/Extensions/ + EXAppExtensionAttributes) | при апгрейде ОС сверять канон с системными виджетами в /System/Applications/*/Contents/PlugIns |

## Поэтапный план

Гейт chronod сработал, поэтому носитель "виджета" в v0.5 — свой, а WidgetKit-трек условный:

- **v0.5a (сейчас, ad-hoc): минимальный статический "виджет" без WidgetKit.**
  (1) Widget-ready snapshot-файл (формат выше, версионированный) — писать после каждого поллинга;
  (2) NSPanel-карточка на рабочем столе: non-activating панель с тем же SwiftUI/AppKit-вью, что и
  меню, toggle "Show desktop card" в меню; ноль extension-механики, полностью в рамках zero-deps
  (подход Ubersicht).
- **v0.5b (сейчас): live-данные.** Карточка обновляется из того же поллера; CLI-режим
  `limit-monitor --status --json` поверх снапшота — этого достаточно для SwiftBar/xbar/Raycast
  (их "виджеты" не требуют подписи и закрывают ту же потребность); пороговые уведомления через
  существующий Notifier.
- **v0.5w (условный, при появлении Developer ID): настоящий WidgetKit-виджет** по
  законсервированному рецепту: (a) статический минимум -> go/no-go чек по логу chronod (нет
  "purging instead") -> (b) live-данные: чтение снапшота в getTimeline + reloadAllTimelines() из
  хоста, таймлайн с предзаложенными reset-состояниями.

## Fallback: chronod нас отверг — применяем

1. **NSPanel-карточка (рекомендуется, = v0.5a/b выше)** — постоянно видимый мини-дашборд без
   WidgetKit, работает под ad-hoc.
2. **Snapshot + CLI -> SwiftBar/xbar/Raycast** — сторонние menu-bar/виджет-хосты читают наш JSON;
   рецепт плагина в доки.
3. **Богаче меню**: секции по провайдерам, прогресс-шкалы (NSAttributedString/SF Symbols), время
   до reset; опциональные дополнительные NSStatusItem per-provider (toggle в конфиге).
4. **CI-гибрид**: релизный .appex собирает GitHub Actions macOS-runner с Xcode (xcodebuild или
   XcodeGen project.yml — путь CodexBar, коммит 487a78ce); локальная разработка без виджета.
   Аварийный выход — однократный xcodeproj в репо (нарушает констрейнт "без Xcode", держать как
   задокументированный запасной).
5. **Developer ID** — единственная настоящая разблокировка ad-hoc-гейта.

Важно: фолбэк через AppIntents/App Shortcuts НЕ работает без Xcode — метаданные интентов
генерирует appintentsmetadataprocessor, которого нет в Command Line Tools (проверено на этой
машине: xcrun его не находит); без Metadata.appintents Shortcuts интентов не увидит. Не
планировать.

## Эксперименты и источники

- Локальный эксперимент 1 (сборка + регистрация): scratchpad widget-test/ и widget-spm/ —
  swiftc и SwiftPM с `-e _NSExtensionMain`; поведение бинаря = настоящий appex; ad-hoc + sandbox
  подпись ок; после lsregister + open виджет виден в `pluginkit -m -p
  com.apple.widgetkit-extension`; контейнер спровизионирован. Система очищена.
- Локальный эксперимент 2 (гейт): scratchpad wtest/ — chronod purge verbatim ("...isApple?
  false", Descriptors Count: 0) на двух независимых бандлах; контроль Stats Descriptors Count: 6;
  spctl: Stats accepted (Notarized Developer ID) vs ad-hoc rejected; 0 identities; вскрытие
  Stats.appex (entry _NSExtensionMain, entitlements sandbox + TEAMID-группа). Система очищена.
- CodexBar: issues #1095 (entry point), #121 и #533 (app groups / TeamID, галерея), коммит
  487a78ce (Xcode-фолбэк), Scripts/package_app.sh, WidgetExtension/{Info.plist,project.yml},
  docs/widgets.md (debug-плейбук pluginkit/chronod).
- Apple: developer forums thread 718589 ("plug-ins must be sandboxed"), thread 776087 и 721701
  (Quinn/DTS: ad-hoc без team ID; App Groups macOS vs iOS), Entitlement Key Reference
  (temporary-exception), WidgetKit docs (creating-a-widget-extension,
  keeping-a-widget-up-to-date, reloadAllTimelines).
- Eclectic Light (pluginkit/pkd, appex-обзор, контейнеры Sonoma/Sequoia), mjtsai (group.* в
  Sequoia), theevilbit beyond_0026/0033 (pkd sandbox-требование, chronod-инфраструктура),
  insidegui gist (lsregister-трюк).
