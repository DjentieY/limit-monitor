# Балансы и квоты провайдеров: API-ресёрч для v0.4

Синтез верифицированного ресёрча (2026-07-16/17): первичные доки, официальные SDK/плагины,
shipping-трекеры (CodexBar, openusage, one-api, coinbase/agentkit), live-пробы endpoint'ов с этой
машины, adversarial-верификация каждого клейма. Все поправки верификаторов внесены в текст.

## Сводная таблица

| Провайдер | Endpoint | Auth | Семантика | Валюта | Рекомендация | Confidence |
|---|---|---|---|---|---|---|
| OpenRouter | GET openrouter.ai/api/v1/key (+ /api/v1/credits) | Bearer, обычный ключ sk-or-v1 (/credits тяготеет к management-ключу) | prepaid-кошелёк + опц. пер-ключевой лимит | USD | builtin | high |
| DeepSeek | GET api.deepseek.com/user/balance | Bearer, единственный тип ключа | prepaid-кошелёк | CNY или USD | builtin | high |
| Moonshot Kimi | GET api.moonshot.{ai,cn}/v1/users/me/balance | Bearer, platform-ключ (не sk-kimi-) | prepaid-кошелёк | USD (.ai) / CNY (.cn) | builtin | high |
| Zhipu GLM | GET {api.z.ai, open.bigmodel.cn}/api/monitor/usage/quota/limit | raw key (Bearer тоже принимается) | квота Coding Plan: 5h + weekly, готовый percent | — (токены/вызовы) | builtin | high |
| SiliconFlow | GET api.siliconflow.{com,cn}/v1/user/info | Bearer | prepaid-кошелёк | USD (.com, inferred) / CNY (.cn) | builtin-preset | high |
| Novita | GET api.novita.ai/openapi/v1/billing/balance/detail | Bearer | prepaid-кошелёк (1/10000 USD) | USD | builtin-preset | high |
| Hyperbolic | GET api.hyperbolic.xyz/billing/get_current_balance | Bearer | prepaid-кошелёк (центы) | USD | generic-recipe | high, endpoint semi-official |
| xAI | GET management-api.x.ai/v1/billing/teams/{teamId}/prepaid/balance | Bearer, management-ключ | prepaid-леджер (центы, знак инвертирован) | USD | generic-recipe | high |
| OpenAI API | GET api.openai.com/v1/organization/costs | Bearer sk-admin- (scope api.usage.read) | spend-to-date; баланса НЕТ | USD | builtin, отложить до v0.5 | high |
| Anthropic API | GET api.anthropic.com/v1/organizations/cost_report | x-api-key sk-ant-admin01- | spend-to-date; баланса НЕТ | USD | builtin, отложить до v0.5 | high |
| Alibaba / Qwen | RPC QueryAccountBalance @ business{,.ap-southeast-1}.aliyuncs.com | AccessKeyId+Secret, подпись ACS3-HMAC-SHA256 | баланс всего облачного аккаунта | CNY/USD/JPY | builtin, отложить (по спросу) | high |
| Groq, Mistral, Cerebras, Together | нет API (только консоль) | — | — | — | document-only | high |
| Fireworks | только gRPC (gateway.fireworks.ai:443) | — | — | — | document-only | high |

Ключевой общий факт: почти все балансы — prepaid-кошельки БЕЗ знаменателя. Натуральный процент
есть только у GLM Coding Plan и у OpenRouter-ключа с заданным limit. Остальным — абсолютный
остаток + пороги (или псевдопроцент против referenceAmount из конфига).

---

## 1. OpenRouter

Запрос (primary, работает с обычным inference-ключом sk-or-v1-...):

```
GET https://openrouter.ai/api/v1/key
Authorization: Bearer <OPENROUTER_API_KEY>
Accept: application/json
```

Опциональное обогащение: `GET https://openrouter.ai/api/v1/credits` (те же заголовки) — баланс
аккаунта. Доки 2026 гейтят его management-ключами (403 "Only management keys can fetch credits"),
но shipping-трекеры получают 200 обычным ключом; 401/403 трактовать как "нет данных", не как
ошибку. Legacy-алиас `/api/v1/auth/key` существует — не использовать.

Ответ /key — `{"data": {...}}`: `label`; `usage` (lifetime USD ключа); `usage_daily` /
`usage_weekly` (UTC Пн-Вс) / `usage_monthly` (UTC-месяц); `byok_usage*`; `is_free_tier`;
`is_management_key`; `limit`, `limit_remaining`, `limit_reset` (null | daily | weekly | monthly) —
все nullable; `include_byok_in_limit`; `expires_at` (nullable ISO 8601); `creator_user_id`
(nullable — по официальному SDK); deprecated: `is_provisioning_key`, `rate_limit` (всегда -1,
игнорировать). Все суммы — float USD.

Ответ /credits: `{"data": {"total_credits": N, "total_usage": N}}` — lifetime-кумулятивы,
баланс = разность; защитно парсить опциональный `data.remaining_balance`.

Синтетический пример:

```json
{"data":{"label":"sk-or-v1-0e6...1c96","usage":25.5,"usage_daily":0.42,"usage_weekly":3.17,
 "usage_monthly":12.04,"byok_usage":0,"byok_usage_daily":0,"byok_usage_weekly":0,
 "byok_usage_monthly":0,"is_free_tier":false,"is_management_key":false,
 "is_provisioning_key":false,"limit":100,"limit_remaining":74.5,"limit_reset":"monthly",
 "include_byok_in_limit":false,"expires_at":null,"rate_limit":{"requests":-1,"interval":"10s"}}}
```
```json
{"data":{"total_credits":100.5,"total_usage":25.75}}
```

Сегмент меню-бара: если у ключа задан `limit` — percent-left = limit_remaining/limit*100, окно по
`limit_reset`; иначе абсолют: баланс из /credits (total_credits - total_usage) либо
usage_daily/usage_monthly из /key. Значения на сервере кэшируются ~60 с — 5-мин поллинг безопасен.

Риски: (1) RU geo-block подтверждён живьём: с московского IP все /api/v1/* (включая публичный
/models) отдают 403 `{"success":false,"error":"Access denied by security policy."}` без обёртки
data — маппить в состояние "blocked/unreachable", НЕ "bad key"; для теста нужен VPN. (2) Ошибки
могут приходить HTML-челленджем Cloudflare — парсить защитно. (3) `label` эхоит усечённый ключ —
тела ответов не логировать. (4) Все nullable-поля обязаны быть Optional в декодере. (5) /credits
может ужесточиться до management-only — держать вторичным.

## 2. DeepSeek

```
GET https://api.deepseek.com/user/balance
Authorization: Bearer <DEEPSEEK_API_KEY>
Accept: application/json
```

Единственный тип ключа (platform.deepseek.com/api_keys), без скоупов. Ответ:

```json
{"is_available": true, "balance_infos": [{"currency": "USD", "total_balance": "23.45",
 "granted_balance": "5.00", "topped_up_balance": "18.45"}]}
```

Все три суммы — decimal-СТРОКИ (официальная схема), наивный числовой декодер упадёт.
`balance_infos` может содержать несколько валютных записей — предпочитать USD, иначе первую.
`total_balance = granted + topped_up`.

Сегмент: абсолютный остаток + валюта из записи; `is_available=false` — красный (инференс вернёт
402); процента нет — пороги/референс из конфига. Риски низкие: WAF нет (чистый JSON 401 на кривой
ключ, проверено живьём), rate limit конкурентный (5-мин поллинг безопасен), эндпоинт стабилен с
2024, деprecation моделей 2026-07-24 его не касается; переживать транзиентные 5xx без алармов.

## 3. Moonshot Kimi

```
GET https://api.moonshot.ai/v1/users/me/balance      # международный, USD
GET https://api.moonshot.cn/v1/users/me/balance      # китайский, CNY
Authorization: Bearer <MOONSHOT_API_KEY>
```

Ключи региональны (401 на чужом хосте) — адаптеру нужен переключатель региона. Ответ — свой
конверт, читать `data.available_balance`:

```json
{"code": 0, "data": {"available_balance": 12.34567, "voucher_balance": 2.5,
 "cash_balance": 9.84567}, "scode": "0x0", "status": true}
```

`available_balance = cash + voucher`; cash может уйти в минус (задолженность), voucher — нет.
Валюты в ответе НЕТ — она определяется хостом. Ошибки другим конвертом:
`{"error":{"message":"Invalid Authentication","type":"invalid_authentication_error"}}` (HTTP 401).
При исчерпании инференс даёт 429 `exceeded_current_quota_error`, balance-endpoint продолжает
отвечать 200.

Сегмент: абсолютный остаток, цвет по порогам. Риски: (1) работает только с open-platform ключами
sk-...; ключи Kimi Coding Plan (sk-kimi-...) — отдельная система api.kimi.com/coding/v1, её квота
здесь не видна (возможный будущий адаптер). (2) Ребрендинг moonshot->kimi: доки переехали по 301,
API-хосты пока прежние (api.kimi.ai не резолвится) — следить. (3) WAF нет (проверено живьём на
обоих хостах). Биллинговые агрегаты дашборда обновляются раз в сутки, сам баланс — почти realtime.

## 4. Zhipu GLM (Coding Plan) — лучший fit под UI приложения

```
GET https://api.z.ai/api/monitor/usage/quota/limit          # международный
GET https://open.bigmodel.cn/api/monitor/usage/quota/limit  # Китай (dev.bigmodel.cn — третий вариант)
Authorization: <API_KEY>            # официальный плагин шлёт raw key БЕЗ "Bearer"; Bearer тоже принимается
Accept-Language: en-US,en           # иначе CN-хост локализует msg
Content-Type: application/json
```

Эндпоинт отсутствует в API-reference, но это API официального плагина Z.ai (zai-org/
zai-coding-plugins, glm-plan-usage); его же используют openusage (нативный Swift menubar) и др.
Квота подписки GLM Coding Plan (Lite ~80 / Pro ~400 / Max ~1600 промптов за 5 ч): rolling 5h-окно +
weekly-окно + месячный счётчик MCP/web-search — модель окон как у Claude.

Реалистичный пример (по live-фикстуре openusage; у TOKENS_LIMIT НЕТ абсолютных чисел — только
percentage + nextResetTime; абсолюты есть только у TIME_LIMIT):

```json
{"code":200,"msg":"success","success":true,"data":{"level":"pro","limits":[
 {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":37.4,"nextResetTime":1784629800000},
 {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":12.0,"nextResetTime":1785061800000},
 {"type":"TIME_LIMIT","unit":5,"number":1,"currentValue":132,"usage":2000,"remaining":1868,
  "percentage":6.6,"nextResetTime":1786519800000,
  "usageDetails":[{"modelCode":"search-prime","usage":90},{"modelCode":"web-reader","usage":42}]}]}}
```

Правила декодирования (все критичны):
- Ошибки приходят как HTTP 200 + `success:false`. Ветвить по `code`: `1001` = auth-ошибка
  (нет/битый ключ); `500` + подстрока "coding plan" в `msg` = нет подписки (PAYG-ключ) — состояние
  "no-plan", не ошибка. Иначе битый ключ отобразится как "нет подписки".
- `percentage` — готовый процент ИСПОЛЬЗОВАННОГО, читать напрямую; remaining = 100 - percentage.
  Не ожидать currentValue/usage/total у TOKENS_LIMIT.
- Поле-ловушка: `usage` = ЛИМИТ, `currentValue` = израсходовано (подтверждено полем `remaining =
  usage - currentValue` и маппингом официального плагина).
- Окна: `unit` (3=часы, 4=дни, 5=месяцы, 6=недели) x `number`; длительность <24h = 5h-метр,
  >=24h = weekly. `nextResetTime` — epoch ms, есть и у TIME_LIMIT.
- Лениентно: старые ревизии используют `name` вместо `type`; `usageDetails` — МАССИВ
  `[{modelCode, usage}]`; все поля опциональны.
- Опциональное обогащение: GET /api/biz/subscription/list (тот же auth) — имя плана в
  data[].productName; best-effort.

Сегмент: 1-2 percent-сегмента (5h + weekly) с точкой и countdown до reset — идентично Claude.
Деньги PAYG-кошелька Zhipu через API НЕ доступны вообще (консоль only; проверено по llms.txt обоих
порталов и отсутствию в one-api). Риски: внутренний API консоли — может измениться без нотиса
(но вендор шипит против него собственный плагин); нужен переключатель хоста; ключи привязаны к
платформе.

## 5. SiliconFlow

```
GET https://api.siliconflow.com/v1/user/info    # международный (валюта USD — inferred, medium)
GET https://api.siliconflow.cn/v1/user/info     # Китай (CNY); регионы = раздельные аккаунты/ключи
Authorization: Bearer <API_KEY>
```

```json
{"code": 20000, "message": "OK", "status": true, "data": {"id": "user_0001", "name": "",
 "image": "", "email": "", "isAdmin": false, "balance": "3.50", "status": "normal",
 "introduction": "", "role": "", "chargeBalance": "20.00", "totalBalance": "23.50"}}
```

Деньги — decimal-СТРОКИ. Читать `data.totalBalance` (= balance гифтовый + chargeBalance платный).
Поля name/image/email deprecated (после June 11 — фиксированные пустые строки), не парсить.
Сегмент: абсолютный остаток + пороги. Валюта в ответе не помечена — по хосту.

## 6. Novita

```
GET https://api.novita.ai/openapi/v1/billing/balance/detail
Authorization: Bearer <API_KEY>
Content-Type: application/json
```

```json
{"availableBalance": "1234500", "cashBalance": "1200000", "creditLimit": "0",
 "pendingCharges": "0", "outstandingInvoices": "34500"}
```

Все поля — СТРОКИ-целые в 1/10000 USD (официальная единица: 10000 = $1.00): remaining =
availableBalance / 10000. `creditLimit` — максимально допустимый долг, не квота. Официальный
стабильный Basic API. Сегмент: абсолют USD + пороги.

## 7. Hyperbolic (semi-official)

```
GET https://api.hyperbolic.xyz/billing/get_current_balance
Authorization: Bearer <API_KEY>
```

Ответ: `{"credits": 2350}` — int в центах USD (remaining = credits/100). Эндпоинта нет в публичных
REST-доках; источник — собственные AgentKit/CLI вендора (и coinbase/agentkit). Компаньон
/billing/purchase_history -> {purchase_history:[{amount, timestamp, source}]}. Риск: идёт
ребрендинг hyperbolic.xyz -> hyperbolic.ai; API-хост пока api.hyperbolic.xyz (проверено живьём,
403 на кривой ключ), но переезд вероятен — поэтому generic-recipe, не builtin.

## 8. xAI

```
GET https://management-api.x.ai/v1/billing/teams/{teamId}/prepaid/balance
Authorization: Bearer <MANAGEMENT_KEY>    # отдельный тип ключа из console.x.ai -> Settings -> Management Keys
```

Обычный inference-ключ НЕ работает; teamId пользователь берёт из консоли. Ответ — леджер:

```json
{"changes": [{"changeOrigin": "PURCHASE", "amount": {"val": "-2500"}, "createTs": "2026-05-01T10:00:00Z"},
 {"changeOrigin": "SPEND", "amount": {"val": "183"}, "createTs": "2026-06-10T21:40:00Z"}],
 "total": {"val": "-2317"}}
```

Центы-строки, знак инвертирован: PURCHASE отрицательный, SPEND положительный; ОТРИЦАТЕЛЬНЫЙ
total = остаток кредита. remaining USD = max(0, -total.val)/100. Парсить только `total` (массив
changes растёт с историей, пагинация не верифицирована). Команды без prepaid-кредита получают
404 — деградировать мягко ("no-plan"). Официально документировано (docs.x.ai, Management API);
сам docs.x.ai за медленным WAF — на runtime не влияет. Из-за ограничения по типу ключа + teamId —
generic-recipe.

## 9. OpenAI Platform (только spend, баланса НЕТ)

Баланс/остаток кредитов НЕ существует для API-ключей — подтверждено модератором форума OpenAI
(ноя 2025); legacy /dashboard/billing/* (credit_grants, usage, subscription) с ~2023 требуют
browser session key и мертвы для sk-ключей (проверено живьём) — не строиться на них. Официальный
путь — Costs API:

```
GET https://api.openai.com/v1/organization/costs?start_time={unix начала месяца UTC}&limit=31
Authorization: Bearer <OPENAI_ADMIN_KEY>    # sk-admin-..., создаёт только Owner организации
```

Ключу достаточно scope api.usage.read — при создании ограничить до "Usage: Read". bucket_width
только "1d"; пагинация has_more/next_page (page=...); фильтры project_ids[]/api_key_ids[]/
group_by[]. Ответ:

```json
{"object": "page", "data": [{"object": "bucket", "start_time": 1751328000, "end_time": 1751414400,
  "results": [{"object": "organization.costs.result", "amount": {"value": 1.2745,
  "currency": "usd"}, "line_item": null, "project_id": null}]},
 {"object": "bucket", "start_time": 1751414400, "end_time": 1751500800, "results": []}],
 "has_more": false, "next_page": null}
```

Spend месяца = сумма data[].results[].amount.value. Сегмент: "$12.47 из $50 (25%)" против
budget_usd из конфига приложения (лимиты бюджета через API не читаются); без бюджета — голый
абсолют. Риски: только владельцы организаций; интрадей-данные лагают (последний бакет дорастает);
404 бывал транзиентным (инцидент 8-9 ноя 2025) — не трактовать как исчезновение API; баг
December 2025 с правами restricted-ключа лечится пересозданием ключа. api.openai.com без
Cloudflare для plain URLSession (проверено).

## 10. Anthropic API (только spend, баланса НЕТ)

GET /v1/organizations/balance -> 404 (проверено живьём); feature request закрыт "not planned".
Официальный путь — Admin API:

```
GET https://api.anthropic.com/v1/organizations/cost_report?starting_at=2026-07-01T00:00:00Z&bucket_width=1d&limit=31
x-api-key: <sk-ant-admin01-...>
anthropic-version: 2023-06-01
User-Agent: limit-monitor/<version> (repo URL)
```

Admin-ключ доступен только организациям (роль admin); индивидуальные аккаунты — никак; обычный
sk-ant-api03 получает 401/403 (ветвить по префиксу ключа, сообщать "нужен admin key"). Ответ:

```json
{"data":[{"starting_at":"2026-07-15T00:00:00Z","ending_at":"2026-07-16T00:00:00Z",
  "results":[{"amount":"1234.56","currency":"USD","workspace_id":null,"description":null,
  "cost_type":null,"model":null,"service_tier":null,"token_type":null,"context_window":null,
  "inference_geo":null}]}],"has_more":false,"next_page":null}
```

КРИТИЧНО: `amount` — decimal-СТРОКА в ЦЕНТАХ ("1234.56" = $12.3456) — суммировать Decimal'ом по
бакетам И results, делить на 100. Бакеты — UTC-сутки; месяц считать по UTC. Пагинацию
has_more/next_page уважать (group_by умножает results). Компаньон
/v1/organizations/usage_report/messages — токены (вторичная строка "tokens today"); его
service_tier enum шире (standard|batch|flex|flex_discount|priority|priority_on_demand) — не
хардкодить. Сегмент: как у OpenAI — spend против budget из конфига. Поллинг: доки блессуют
<=1/мин — 5 мин с запасом. Данные лагают ~5 мин. Priority Tier в cost_report не виден; AWS-орги и
Claude Enterprise — вне этого API. Admin-ключ высокопривилегирован — рекомендовать expiration,
никогда не логировать.

## 11. Alibaba Cloud / Qwen (отложить; единственный с подписью)

DashScope-нативного баланса/квоты НЕТ: sk-ключ DashScope умеет только модельные API; free-quota и
Coding Plan — консоль-only (доки: "not currently supported"). Официальный путь — BSS OpenAPI
QueryAccountBalance (2017-12-14), баланс ВСЕГО облачного аккаунта:

```
POST https://business.aliyuncs.com/                     # China-site аккаунты
POST https://business.ap-southeast-1.aliyuncs.com/      # international
x-acs-action: QueryAccountBalance
x-acs-version: 2017-12-14
x-acs-date: <ISO8601 UTC, +-15 мин от серверного>
x-acs-signature-nonce: <UUID на запрос>
x-acs-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Authorization: ACS3-HMAC-SHA256 Credential=<AccessKeyId>,SignedHeaders=...,Signature=<hex hmac>
```

Auth = Alibaba Cloud AccessKeyId+AccessKeySecret (НЕ DashScope sk-). Подпись V3 без derivation
(raw secret как HMAC-ключ) — реализуема на CryptoKit в ~100-150 строк Swift; legacy V1
(HMAC-SHA1) — фолбэк. RAM: выделенный read-only пользователь с политикой AliyunBSSReadOnlyAccess
(action "bss:DescribeAcccount", sic). Ответ (деньги — строки, возможны разделители тысяч
"1,234.56" — вычищать запятые):

```json
{"Code":"200","Message":"success","RequestId":"8B62AB2F-...","Success":true,
 "Data":{"AvailableAmount":"142.57","AvailableCashAmount":"142.57","CreditAmount":"0.00",
 "MybankCreditAmount":"0.00","Currency":"USD","QuotaLimit":"0"}}
```

Читать Data.AvailableAmount + Currency; QuotaLimit не парсить (варьируется по типу аккаунта).
Сегмент: абсолют + пороги; Qwen-специфичного процента не существует — сказать это в доках.
Rate limit 10 QPS. Риски: два секрета + селектор сайта в конфиге; мощный кредишиал (только
read-only RAM-user!); хрупкость канонизации подписи; "not applicable for caller" у
reseller-аккаунтов. Generic-адаптер это выразить НЕ может (динамические date/nonce/HMAC) —
builtin-only, делать по спросу.

## 12. Без API (document-only)

- Groq — биллинг только в консоли (billing-faqs); есть лишь rate-limit заголовки на inference.
- Mistral — только console.mistral.ai (Billing/Credits).
- Cerebras — только Billing tab; программно виден лишь 402 при исчерпании.
- Together AI — кредиты только в billing UI; скрытые эндпоинты сломались после смены auth.
- Fireworks — баланс только через gRPC (gateway.fireworks.ai:443, GatewayService, Money proto) —
  несовместимо с HTTP-JSON адаптером.
- Нет источника в принципе: prepaid-баланс OpenAI и Anthropic; PAYG-кошелёк Zhipu; free-quota и
  Coding Plan Qwen; квота Kimi Coding Plan (отдельная система api.kimi.com/coding/v1 — кандидат
  на будущий отдельный адаптер).

---

## Единый маппинг состояний адаптеров

| Состояние | Триггеры |
|---|---|
| ok / warn / critical | пороги thresholds (percent-mode: остаток %; balance-mode: остаток в валюте); DeepSeek is_available=false -> critical |
| blocked / unreachable | сеть, таймаут, 5xx; OpenRouter geo-403 `{"success":false,"error":"Access denied by security policy."}` |
| bad-key | HTTP 401/403 auth; Kimi `{"error":{"type":"invalid_authentication_error"}}`; GLM HTTP 200 + code 1001 |
| no-plan | GLM HTTP 200 + code 500 + "coding plan" в msg; xAI 404 без prepaid |

Поллинг раз в ~5 мин безопасен у всех: Anthropic документирует <=1/мин, Alibaba 10 QPS, OpenRouter
кэширует ~60 с, остальные — единичные лёгкие GET.

## Рекомендуемый скоуп v0.4

1. **Builtin-адаптеры (код, 4 шт.):** OpenRouter, DeepSeek, Moonshot Kimi, Zhipu GLM.
   Обоснование: официальные/vendor-blessed стабильные GET, high confidence, топовый спрос; их
   логика невыразима generic-движком (двойной вызов с fallback у OpenRouter; ветвление code
   1001/500 и выбор окон у GLM; регион-переключатели и конверты у Kimi; мультивалютный массив +
   okFlag у DeepSeek).
2. **Builtin-пресеты поверх generic-движка (2 шт.):** SiliconFlow, Novita — тривиальные
   официальные GET; шипятся как встроенные generic-конфиги, пользователь указывает только
   источник ключа.
3. **Generic-рецепты (только документация, JSON ниже):** Hyperbolic, xAI; плюс альтернативные
   рецепты DeepSeek/Kimi для желающих обойтись без builtin.
4. **v0.5-кандидаты (builtin):** OpenAI Costs и Anthropic cost_report — admin-ключи, динамическое
   месячное окно, суммирование бакетов, budget_usd в конфиге; семантика "spend vs budget", а не
   баланс. Alibaba BSS — по спросу (ACS3-подписыватель).
5. **Document-only:** раздел 12 целиком — зафиксировать в README, чтобы не отвечать на issue.

## Дизайн generic-адаптера: ~/.config/limit-monitor/providers.json

```json
{
  "version": 1,
  "defaults": { "pollSeconds": 300 },
  "providers": [
    {
      "id": "siliconflow",
      "name": "SiliconFlow",
      "label": "SF",
      "kind": "generic-http",
      "enabled": true,
      "key": { "command": "security find-generic-password -s siliconflow-api -w" },
      "request": {
        "url": "https://api.siliconflow.com/v1/user/info",
        "method": "GET",
        "headers": { "Authorization": "Bearer ${KEY}" },
        "timeoutSeconds": 15
      },
      "extract": {
        "balance": { "path": "data.totalBalance", "scale": 1.0 },
        "limit": null,
        "percentUsed": null,
        "okFlag": null
      },
      "display": { "mode": "balance", "currency": "USD", "referenceAmount": null },
      "thresholds": { "warn": 5.0, "critical": 1.0 }
    }
  ]
}
```

| Поле | Смысл |
|---|---|
| id | стабильный слаг; ключ кэша состояния |
| name / label | имя в меню / короткая метка сегмента в строке меню |
| kind | "generic-http" либо id builtin-адаптера ("openrouter", "deepseek", "moonshot", "zhipu", "siliconflow", "novita"); builtin-ы берут из этой же записи key и свои опции (host/region, budgetUsd, teamId) |
| key | РОВНО один из `literal` / `env` / `command`; command исполняется `/bin/sh -c` с таймаутом, stdout трим; значение живёт только в памяти, никогда в логах. Дизайн-примечание: env-источник ненадёжен при запуске из Finder (окружение launchd) — рекомендовать command, например Keychain через `security find-generic-password -w` |
| request | url, method (GET), headers; плейсхолдер `${KEY}` подставляется в значения заголовков и URL (GLM-стиль "raw key" выражается как `"Authorization": "${KEY}"`) |
| extract.balance / extract.limit | `{ path, scale=1.0, clampMin? }`; значение по dot-path — JSON-число ИЛИ decimal-строка (запятые тысяч вычищаются); scale — множитель (Novita 0.0001, Hyperbolic 0.01, xAI -0.01) |
| extract.percentUsed | путь к готовому проценту 0..100 (percent-mode) |
| extract.okFlag | путь к bool; false -> принудительно critical |
| display.mode | "balance" / "percent"; авто-правило: percentUsed -> percent; balance+limit -> percent = balance/limit; иначе balance (+referenceAmount -> псевдопроцент) |
| display.currency | метка для отображения, без конвертации |
| thresholds | percent-mode: warn/critical по остатку в %; balance-mode: по остатку в валюте |

Dot-path: сегменты через ".", числовой сегмент — индекс массива: `balance_infos.0.total_balance`,
`total.val`, `credits`. Файл конфига — chmod 600; тела ответов и заголовки с ключом не логировать.

Generic-движок сознательно НЕ умеет (это граница builtin): арифметику двух полей
(OpenRouter total_credits - total_usage), выбор элемента массива по значению поля (GLM limits по
type/окну), динамические параметры дат (месячное окно OpenAI/Anthropic), подписи запросов
(Alibaba ACS3), цепочки запросов с fallback (OpenRouter /key -> /credits).

## Рецепты generic-конфигов

Hyperbolic:

```json
{ "id": "hyperbolic", "name": "Hyperbolic", "kind": "generic-http",
  "key": { "env": "HYPERBOLIC_API_KEY" },
  "request": { "url": "https://api.hyperbolic.xyz/billing/get_current_balance",
               "headers": { "Authorization": "Bearer ${KEY}" } },
  "extract": { "balance": { "path": "credits", "scale": 0.01 } },
  "display": { "mode": "balance", "currency": "USD" },
  "thresholds": { "warn": 5, "critical": 1 } }
```

xAI (management-ключ, teamId вставить в URL; 404 = нет prepaid):

```json
{ "id": "xai", "name": "xAI", "kind": "generic-http",
  "key": { "env": "XAI_MANAGEMENT_KEY" },
  "request": { "url": "https://management-api.x.ai/v1/billing/teams/<TEAM_ID>/prepaid/balance",
               "headers": { "Authorization": "Bearer ${KEY}" } },
  "extract": { "balance": { "path": "total.val", "scale": -0.01, "clampMin": 0 } },
  "display": { "mode": "balance", "currency": "USD" },
  "thresholds": { "warn": 5, "critical": 1 } }
```

SiliconFlow (пресет; для .cn — url api.siliconflow.cn, currency CNY):

```json
{ "id": "siliconflow", "name": "SiliconFlow", "kind": "generic-http",
  "key": { "env": "SILICONFLOW_API_KEY" },
  "request": { "url": "https://api.siliconflow.com/v1/user/info",
               "headers": { "Authorization": "Bearer ${KEY}" } },
  "extract": { "balance": { "path": "data.totalBalance" } },
  "display": { "mode": "balance", "currency": "USD" },
  "thresholds": { "warn": 5, "critical": 1 } }
```

Novita (пресет):

```json
{ "id": "novita", "name": "Novita", "kind": "generic-http",
  "key": { "env": "NOVITA_API_KEY" },
  "request": { "url": "https://api.novita.ai/openapi/v1/billing/balance/detail",
               "headers": { "Authorization": "Bearer ${KEY}", "Content-Type": "application/json" } },
  "extract": { "balance": { "path": "availableBalance", "scale": 0.0001 } },
  "display": { "mode": "balance", "currency": "USD" },
  "thresholds": { "warn": 5, "critical": 1 } }
```

DeepSeek как generic (альтернатива builtin; первая валютная запись):

```json
{ "id": "deepseek-generic", "name": "DeepSeek", "kind": "generic-http",
  "key": { "env": "DEEPSEEK_API_KEY" },
  "request": { "url": "https://api.deepseek.com/user/balance",
               "headers": { "Authorization": "Bearer ${KEY}" } },
  "extract": { "balance": { "path": "balance_infos.0.total_balance" },
               "okFlag": { "path": "is_available" } },
  "display": { "mode": "balance", "currency": "USD" },
  "thresholds": { "warn": 3, "critical": 0.5 } }
```

Kimi как generic (международный хост):

```json
{ "id": "kimi-generic", "name": "Kimi", "kind": "generic-http",
  "key": { "env": "MOONSHOT_API_KEY" },
  "request": { "url": "https://api.moonshot.ai/v1/users/me/balance",
               "headers": { "Authorization": "Bearer ${KEY}" } },
  "extract": { "balance": { "path": "data.available_balance" } },
  "display": { "mode": "balance", "currency": "USD" },
  "thresholds": { "warn": 3, "critical": 0.5 } }
```
