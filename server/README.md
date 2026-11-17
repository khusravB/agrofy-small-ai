# AGROFY SMS server

Backend for the two SMS features: a farmer asks a question or requests NASA data
by ordinary SMS, and the server replies by SMS. The phone app never reads SMS;
it only opens the system SMS app with the number and a prepared text, and the
farmer presses Send.

The server uses the same pure-Dart core as the app (`packages/agrofy_core`):
the observation interpreter, evidence validator, decision engine, rotation
advisor and offline assistant. Answers are the same rule-based answers the app
gives. The only exception is the explicit `/ВОПРОС` command, which asks a
cloud language model (see below).

## Commands

| SMS | What happens |
|---|---|
| `HELP` / `ПОМОЩЬ` / `?` | Short list of commands |
| `REG F1 40.28,69.62 ХЛОПОК` / `РЕГ …` | Registers field F1 for this phone, downloads NASA POWER climate for it once |
| `FIELD F1` / `ПОЛЕ F1` | Makes F1 the active field for questions |
| `/INFO 40.28,69.62 ХЛОПОК ВОДА`, `INFO F5 40.28,69.62 ХЛОПОК ПОЧВА`, `INFO F1 ДОХОД`, `INFO` | Full NASA report for the field and what to sow next, tuned to the goal (`ВОДА`, `ПОЧВА`, `ДОХОД`, `УСТОЙЧИВОСТЬ`): rotations with scores and irrigation, sowing dates, a drought year, climate. A new point is registered as a field automatically; if NASA data still has to be fetched, the report arrives by SMS 1–2 minutes later. The last SMS is a code for the app (see below) |
| `ЕЩЁ` / `MORE`, `ВСЁ` / `ALL` | Next waiting parts of a long answer, or all of them (only when `AGROFY_PAGES_AT_ONCE` is below the number of parts) |
| `FIELDS` / `ПОЛЯ` | Fields registered from this phone |
| `FIELD F1 NDVI 90D` | MODIS NDVI package for F1 (default 90 days, max 366) |
| `FIELD F1 CLIMATE 1Y` | NASA POWER daily temperature and rainfall (default 1 year, max 3) |
| `FIELD F1 HISTORY 3Y` | MODIS NDVI over several seasons (default 3 years, max 5) |
| `FIELD F1 SOWING` | Daily temperature and rainfall for the last year, as context for sowing dates |
| `FIELD 40.28,69.62 DATA 90D` | NDVI and climate for a point without registering it |
| `/ВОПРОС текст` / `/QUESTION text` | Any question to a language model (Claude, see below), with the active field's data as context; the answer arrives as separate SMS a few seconds later |
| `NEW` / `НОВЫЙ` | Forgets the facts of the current conversation |
| `STOP` / `СТОП`, `START` / `СТАРТ` | Opt out and back in |
| any other text | A question: observations ("листья желтеют, почва сухая") go through interpreter → validator → decision engine; other questions go to the offline assistant with the active field's climate |

Periods: `90D`, `3M`, `1Y` (days, months, years). Russian works too:
`ПОЛЕ F1 НДВИ 3М`, `ПОЛЕ F1 КЛИМАТ 1Г` (`КЛИМАТ`/`ПОГОДА`, `ИСТОРИЯ`,
`ПОСЕВ`, `ДАННЫЕ`; periods `Д`, `М`, `Г`).

**Everything works without mobile internet.** An answer that does not fit
one SMS is split into parts of whole sentences, numbered `(1/4)`…`(4/4)`, and
all parts are sent at once, in order; most phones show them one after another
in the same chat. `AGROFY_PAGES_AT_ONCE` limits how many parts go out at once
(default: all, up to `AGROFY_MAX_PAGES`, default 8); the rest wait, the last
part sent ends with `Дальше: ЕЩЁ`, and the farmer sends `ЕЩЁ` for the next
parts or `ВСЁ` for all of them. Waiting parts are kept for 24 hours and dropped
by the next new message. Observation replies put the action and the
"не диагноз" caveat in part 1 and the reasons, plan and options after it.

**Code for the app.** The last SMS of an `INFO` reply is a line of Latin
letters and digits (`AGF1;F1;40.2800;69.6200;cotton;w;…;627e55`, about 340
characters, one SMS): the field, the crop, the goal, NASA POWER monthly
climate (mean, range and maximum temperature, rainfall, frost days, root-zone
wetness), the recommended rotation and a checksum. In the app, «Вставить код
из SMS» checks the checksum, the distance from the field and the crop, then
saves the climate and the goal — the advisor then works offline on the same
NASA data. Year types and trends are not in the code (35 years of history do
not fit an SMS); the app gets them when it has internet once.

Data requests arrive as text too: NDVI as dates and values
(`14.09 0.18; 30.09 0.22; 16.10 0.13 обл.`, monthly means for `HISTORY`),
climate as monthly mean and minimum temperature and rainfall.

Optional links (`AGROFY_REPORT_LINKS=true`, for farmers who sometimes have
internet): long answers then come as their beginning plus
`Полностью: https://<host>/r/<token>`, a plain mobile web page, and data SMS
include the package file link for import into the app. Report links use a
random 96-bit token, expire after 7 days, and are served with `no-store`,
`noindex` and a CSP that allows no scripts.

Replies are at most 3 SMS segments (459 GSM-7 or 201 Cyrillic characters). The
first sentence always carries the "подсказка, не диагноз" caveat.

## Language model (`/ВОПРОС`)

Everything else on the server is the rule-based "small AI" shared with the app.
`/ВОПРОС` is the one place a cloud language model is used, and only when the
operator sets `ANTHROPIC_API_KEY`; without it the command replies that it is
not configured.

- Model: Claude Opus 5.5 (`claude-opus-5-5`) through the Messages API, by
  direct HTTP (there is no official Dart SDK). `AGROFY_LLM_MODEL` and
  `AGROFY_LLM_EFFORT` (default `medium`) change it. Server-side refusal
  fallback (`fallbacks: "default"`) is on for models that support it.
- Sent to the API: the question and the active field's data — crop, the point
  rounded to ~1 km, NASA POWER monthly climate, the advisor's rotations and
  the goal. Not sent: the phone number.
- The system prompt asks for plain text in the farmer's language, at most ~700
  characters, grounded in the field data, without diagnoses, pesticides or
  doses. Replies are marked "AGROFY (ИИ)" and end with a note that this is a
  language model's answer to be checked with an agronomist.
- Limit: `AGROFY_LLM_PER_DAY` questions per phone per day (default 10). The
  audit log records input and output tokens per answer, without the number.
- Plain questions without `/ВОПРОС` keep going to the built-in advisor.

## Data packages

A data request is acknowledged immediately; the package is built in the
background and a second SMS brings the values as text (see above). With
`AGROFY_REPORT_LINKS=true` it also carries a link to the package file:

```
AGROFY REQ-2026-000001: NDVI готов (READY). Файл: https://…/p/<token> Действует 7 дн. Импорт: приложение → AI → Импортировать пакет.
```

- NDVI: MODIS Terra MOD13Q1 (250 m, 16-day) from the ORNL DAAC MODIS web
  service, with the reliability flag for every date (cloudy and snow dates are
  kept but marked, and make the package PARTIAL).
- Climate: NASA POWER daily T2M, T2M_MIN, PRECTOTCORR; days not yet published
  are listed as missing data.
- Format: JSON, schema `agrofy_field_data` 1.0, SHA-256 checksum over the
  datasets. If nothing usable is found, the package is UNAVAILABLE and no link
  is sent.
- Links are random 192-bit tokens, expire after 7 days, and are served as
  downloads (`GET /p/<token>`).

The app checks a package before saving anything: schema, units, checksum,
field id and distance from the field (over 1 km is flagged), duplicates and
values that differ from ones already stored. Imported NDVI becomes context in
the advisor, never an automatic recommendation.

## Security

- Every webhook is authenticated: Vonage by a signed JWT (see Deploy), Twilio by `X-Twilio-Signature` (HMAC-SHA1 of
  the public URL and the sorted parameters), the generic provider by
  `X-Agrofy-Signature` = hex HMAC-SHA256 of `"<timestamp>.<body>"`, where
  `X-Agrofy-Timestamp` (Unix seconds) must be within ±5 minutes. Unsigned or stale requests are rejected (401/403).
- Replays are dropped by message id.
- Limits per phone: 20 messages per hour, 60 per day, 5 data requests per day;
  one warning, then silence. Messages longer than 480 characters are refused.
- A phone only reads its own fields; requests for someone else's field id are
  refused.
- STOP is honoured immediately and stored.
- Phone numbers are stored only in the state file; the audit log keeps salted
  hashes. Conversation facts expire after 24 hours; expired packages are deleted.

## Run locally

```bash
dart pub get
AGROFY_WEBHOOK_SECRET=local-demo-secret-123456 \
AGROFY_PUBLIC_URL=http://localhost:8080 \
dart run bin/server.dart
```

In another terminal:

```bash
AGROFY_WEBHOOK_SECRET=local-demo-secret-123456 dart run bin/simulate.dart +992900000001 "REG F1 40.28,69.62 ХЛОПОК"
```

```bash
AGROFY_WEBHOOK_SECRET=local-demo-secret-123456 dart run bin/simulate.dart +992900000001 "FIELD F1 NDVI 90D"
```

With the generic provider and no `AGROFY_OUTBOUND_URL`, outgoing SMS (such as
the package link) are appended to `<data dir>/outbox.jsonl`.

```bash
dart test
```

## Deploy

Step-by-step guide for a VPS with Docker, Caddy (automatic HTTPS) and Vonage
or Twilio:
[deploy/README.md](deploy/README.md) (in Russian). The image is built from the
repository root:

```bash
docker build -f server/Dockerfile -t agrofy-sms .
```

Note: neither Twilio nor Vonage offers local Tajik numbers, and Twilio states
two-way SMS is not supported there. A foreign number suits a demo once tested
from each operator's SIM; a pilot needs a local gateway (`generic` provider) or
an operator contract.

The server is a single Dart process with a JSON state file; any host that runs
Dart or a Docker image with Dart works. It needs a public HTTPS URL.

| Variable | Meaning |
|---|---|
| `PORT` | Listen port (default 8080) |
| `AGROFY_PUBLIC_URL` | Public base URL; used in links and for Twilio signatures |
| `AGROFY_DATA_DIR` | State, packages and logs (default `./data`) |
| `AGROFY_SMS_PROVIDER` | `vonage`, `twilio` or `generic` (default) |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM` | Twilio account and sender number |
| `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_SIGNATURE_SECRET`, `VONAGE_FROM` | Vonage account (Messages API) and sender number, digits only |
| `AGROFY_WEBHOOK_SECRET` | Generic provider: shared secret, 16+ characters |
| `AGROFY_OUTBOUND_URL` | Generic provider: URL that accepts JSON `{to, text}` to send SMS |
| `AGROFY_AUDIT_SALT` | Salt for phone hashes in the audit log |
| `ANTHROPIC_API_KEY` | Claude API key for `/ВОПРОС` (unset: the command is off) |
| `AGROFY_LLM_MODEL`, `AGROFY_LLM_EFFORT`, `AGROFY_LLM_PER_DAY` | Model (default `claude-opus-5-5`), effort (`medium`), questions per phone per day (10) |
| `AGROFY_MAX_REPLY_SEGMENTS` | SMS segments per page (default 3) |
| `AGROFY_MAX_PAGES` | Parts per long answer (default 8) |
| `AGROFY_PAGES_AT_ONCE` | Parts sent at once; the rest on `ЕЩЁ` (default: all) |
| `AGROFY_REPORT_LINKS` | `true` adds links to web reports and package files (default off: text only) |

Vonage: create an application with the Messages capability, Inbound URL
`https://<host>/sms/vonage`, Status URL `https://<host>/sms/vonage/status`, and
link the number; set the account's SMS setting to Messages API. Webhooks are
verified by the JWT in `Authorization` (HS256 with the signature secret,
`payload_hash` = SHA-256 of the body, issued within the last hour); replies are
sent through `POST /v1/messages`, the webhook itself gets 204.

Twilio: point the number's incoming-message webhook to
`https://<host>/sms/twilio` (HTTP POST). Generic SMS gateways (local operators,
aggregators): POST JSON `{from, text, id}` to `https://<host>/sms/inbound`
with the signature headers above; replies come back as `{"replies": [...]}`.

Not done: no SMS number or provider account exists yet, and the server has
only been run locally with the generic provider. SMS costs follow the
operator's and provider's tariffs.
