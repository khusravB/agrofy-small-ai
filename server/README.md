# AGROFY SMS server

Backend for the two SMS features: a farmer asks a question or requests NASA data
by ordinary SMS, and the server replies by SMS. The phone app never reads SMS;
it only opens the system SMS app with the number and a prepared text, and the
farmer presses Send.

The server uses the same pure-Dart core as the app (`packages/agrofy_core`):
the observation interpreter, evidence validator, decision engine, rotation
advisor and offline assistant. Answers are the same rule-based answers the app
gives; no cloud language model is called.

## Commands

| SMS | What happens |
|---|---|
| `HELP` / `ПОМОЩЬ` / `?` | Short list of commands |
| `REG F1 40.28,69.62 ХЛОПОК` / `РЕГ …` | Registers field F1 for this phone, downloads NASA POWER climate for it once |
| `FIELD F1` / `ПОЛЕ F1` | Makes F1 the active field for questions |
| `FIELD F1 NDVI 90D` | MODIS NDVI package for F1 (default 90 days, max 366) |
| `FIELD F1 CLIMATE 1Y` | NASA POWER daily temperature and rainfall (default 1 year, max 3) |
| `FIELD F1 HISTORY 3Y` | MODIS NDVI over several seasons (default 3 years, max 5) |
| `FIELD F1 SOWING` | Daily temperature and rainfall for the last year, as context for sowing dates |
| `FIELD 40.28,69.62 DATA 90D` | NDVI and climate for a point without registering it |
| `NEW` / `НОВЫЙ` | Forgets the facts of the current conversation |
| `STOP` / `СТОП`, `START` / `СТАРТ` | Opt out and back in |
| any other text | A question: observations ("листья желтеют, почва сухая") go through interpreter → validator → decision engine; other questions go to the offline assistant with the active field's climate |

Periods: `90D`, `3M`, `1Y` (days, months, years). Russian works too:
`ПОЛЕ F1 НДВИ 3М`, `ПОЛЕ F1 КЛИМАТ 1Г` (`КЛИМАТ`/`ПОГОДА`, `ИСТОРИЯ`,
`ПОСЕВ`, `ДАННЫЕ`; periods `Д`, `М`, `Г`).

Replies are at most 3 SMS segments (459 GSM-7 or 201 Cyrillic characters). The
first sentence always carries the "подсказка, не диагноз" caveat.

## Data packages

A data request is acknowledged immediately; the package is built in the
background and a second SMS brings a link:

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
