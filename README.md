# AGROFY Small AI

Offline-first crop-rotation advisor for farmers, built for the 2026 NASA Space Apps
Challenge **"Field Shift: Adapting Farms with NASA Data"**.

The app compares the farmer's current rotation with alternatives using NASA Earth
observations, field properties and the farmer's own priorities. After a one-time
download of NASA data for the field, everything — including the AI — runs on the
phone with no network.

Interface language: Russian. Demo region: Sughd region, Tajikistan.

## What "Small AI" means here

Three small models train and run on the device in pure Dart, with no cloud and
no model download. A fourth, optional one is a small generative language model:

| Model | What it does | Method | Trained on |
|---|---|---|---|
| Year-type model | Splits the field's weather history into dry / normal / wet years and replays every rotation in each | k-means clustering (deterministic init) | 35 years of NASA POWER monthly data for the field's own coordinates |
| Trend detector | Reports whether temperature, rainfall, evaporative demand and frost days are changing | Theil–Sen slope + Mann–Kendall test | Same history |
| Question classifier | Understands the farmer's question in the chat tab | Multinomial naive Bayes over word stems and character trigrams | ~120 bundled example questions |
| Language model (optional) | Adds a two-sentence plain-language note under each answer | Qwen2.5-0.5B-Instruct, 4-bit GGUF, run with llama.cpp via `llamadart` | Pre-trained; downloaded once (491 MB) on the farmer's request |

Answers in the chat are assembled from the advisor's calculations and the offline
knowledge base (BM25 retrieval), so the assistant cannot make facts up and always
names its source. The rotation scoring itself is an explainable rule-based engine,
not a neural network.

The language model is never the source of facts. The exact answer is always
shown; the model only adds a short note, and the note is dropped if it contains
a number that is not in the facts, drifts off topic or is not in Russian
(`packages/agrofy_core/lib/ai/llm_grounding.dart`). A 0.5B model writes imperfect Russian, so treat
the note as a convenience, not as advice. Without the model the app works
exactly the same, minus the note.

## Decision pipeline for field observations

The "Observations" tab follows a strict separation of responsibilities:
the AI understands the input, a validator checks the evidence, deterministic
rules decide, and the result is explained as a plan.

| Layer | Code | Responsibility |
|---|---|---|
| Interpreter | `packages/agrofy_core/lib/decision/observation_interpreter.dart` | Free text → structured facts, each with a source and a status (observed / inferred / unknown) |
| Evidence validator | `packages/agrofy_core/lib/decision/evidence_validator.dart` | Missing data, contradictions between the farmer, the journal, measurements and NASA climate; never picks a side |
| Decision engine | `packages/agrofy_core/lib/decision/decision_engine.dart` | Reproducible rules → a decision code such as `verifySoilMoisture`; asks for a measurement rather than prescribing when evidence is thin |
| Recommendation and plan | same file | Action, reason, evidence, missing information, three alternatives, expected outcome, status, action steps |
| Crop lifecycle | `packages/agrofy_core/lib/decision/crop_lifecycle.dart` | Eight stages, forward-only transitions, each logged to the field journal |
| Field memory and outcomes | `packages/agrofy_core/lib/decision/saved_observation.dart` | Stored observations; a later observation is compared with the earlier recommendation without claiming causality |

The interpreter is a small lexicon model that always works offline. The
optional language model may add features only inside a strict JSON schema, only
about something the farmer actually mentioned, and only as "inferred" — inferred
facts never trigger rules. The decision rules were written by the developers and
have not been reviewed by an agronomist; they deliberately stop at "measure",
"check" and "consult" rather than prescribing treatments.

## Features

- **Rotation advisor** — current rotation plus three alternatives (water saving,
  soil building, income and resilience). Each shows why it was suggested, the
  evidence, benefits, data gaps and risks to review with an agronomist.
- **Rotation length 3–5 years** — exhaustive search up to 4 years, beam search
  for 5; alfalfa is placed as a 2–3-year block. A crop never returns to the
  field sooner than 3 years in a suggestion (second crops included), and a
  second crop is never followed by a main crop of the same family.
- **Year types** — every strategy is scored in dry, normal and wet years.
  Next to the statistical clusters, an agronomic criterion: a year is dry if
  the warm-season water deficit is at least 50 mm (500 m³/ha) above normal.
- **Farmer priorities** — sliders for water, soil, income and weather resilience.
- **"What if" scenario** — rainfall and temperature sliders.
- **Elevation correction** — temperature is adjusted for the difference between
  the field (SRTM) and the NASA POWER grid cell (6.5 °C/km).
- **Frost dates and sowing to the decade** — from 35 years of daily NASA POWER
  data: last spring frost (median and 10% risk), first autumn frost, frost-free
  period; spring sowing when the daily normal reaches the crop's minimum and
  frost risk is ≤10%.
- **Field conditions** — irrigation method losses, soil texture, pH, SRTM slope.
- **Soil card** — salinity class, groundwater depth, humus, N/P/K entered by
  the farmer (unknown stays unknown). Salt tolerance per crop from FAO
  thresholds, waterlogging sensitivity, secondary salinization risk.
- **Income in money** — the farmer enters price, yield and costs; margin per
  hectare per year is shown. Without data the income stays a 1–5 index and the
  gap is listed.
- **Yields vs scores** — recorded yields are compared with the advisor's
  climate score for the same year's weather (Pearson r from 3 years up), and
  the farmer's average yield replaces the typed-in yield in the money
  calculation.
- **Regional tuning** — crops typical for Sughd, second crops after winter cereals.
- **Offline assistant** — chat that answers from the field's own data.
- **Model sharing** — the language model file can be imported from storage
  or shared to another phone (AirDrop, Bluetooth, Nearby Share); every file is
  checked by size, GGUF signature and the official SHA-256 before use.
- **Map** — NASA GIBS layers (MODIS NDVI, SMAP soil moisture, GPM IMERG rainfall,
  MODIS land-surface temperature) and field markers coloured by water stress.
- **Knowledge base** — 22 short offline articles explaining the terms.
- **Observations** — describe what you see in plain words; get extracted facts
  with sources, missing data, contradictions, a recommendation and a plan. The
  interpreter tolerates one typo in long word roots and knows common Russian
  synonyms and basic Tajik words.
- **Crop lifecycle** — eight stages with controlled transitions, stored locally.
- **Field memory** — timeline of observations, irrigations and stage changes.

## SMS channel and satellite data packages

For places with mobile signal but no data connection. Both features need the
AGROFY SMS server (`server/`, see [server/README.md](server/README.md)); the app
itself never reads SMS.

- **Ask by SMS.** In the chat tab, «Спросить по SMS» opens the phone's SMS app
  with the AGROFY number and the question. The farmer presses Send; the server
  answers by SMS with the same interpreter, validator and decision engine as the
  app, using the field's NASA climate. Replies fit in 3 SMS segments and keep the
  "подсказка, не диагноз" caveat. Follow-ups use the facts of the conversation
  (24 hours): "листья желтеют" → "в основном нижние, почва влажная".
- **Field report by SMS, no internet needed.** `INFO F5` (button «Всё о
  поле») returns everything the server knows about the field — rotations with
  scores and irrigation, sowing dates, a drought year, NASA climate and trends —
  as several numbered SMS sent at once. Any long answer works the same way; the
  server can limit how many go out at once (the rest on `ЕЩЁ`). Links to a web
  version are an optional server setting.
- **Satellite data by SMS.** In AI → Советник, the card «SMS и спутниковые
  данные» prepares `REG F5 lat,lon CROP`, `FIELD F5 NDVI 3M` or
  `FIELD F5 CLIMATE 1Y`. The server fetches MODIS NDVI (MOD13Q1, ORNL DAAC)
  or NASA POWER daily data and sends the values as SMS text (NDVI by date,
  climate by month). Optionally it also sends a link to a JSON package that
  the farmer can download when there is a connection and import with
  «Импортировать пакет».
- **Import is checked**: schema version, units, SHA-256 checksum, field id and
  distance from the field, duplicates, and values that differ from stored ones
  (replaced only if the farmer ticks the box). Imported NDVI appears as context
  in the advisor ("NDVI below 0.2 in Aug, Oct…"); it never changes the
  recommendation by itself.

Security on the server: signed webhooks (Vonage JWT, Twilio HMAC-SHA1 or HMAC-SHA256 with a
timestamp), replay protection, per-phone limits, HELP/STOP, owner-only access to
field data, hashed phone numbers in the audit log, random expiring links.

## Data

| Source | Used for | Access |
|---|---|---|
| [NASA POWER](https://power.larc.nasa.gov/) climatology and monthly history | Temperature, rainfall, frost days, root-zone soil wetness; water balance, sowing windows, year types, trends | Downloaded once per field, cached in SQLite |
| NASA POWER daily (T2M, T2M_MIN, 1991–last year) | Frost dates with probability, sowing to the decade | Downloaded once per field, cached |
| NASA POWER daily (T2M, T2M_MIN, PRECTOTCORR), recent period | Climate packages sent by the SMS server | Server; imported as a file |
| [MODIS Terra MOD13Q1](https://lpdaac.usgs.gov/products/mod13q1v061/) NDVI, 250 m, 16-day, via the [ORNL DAAC MODIS web service](https://modis.ornl.gov/data/modis_webservice.html) | Field NDVI series with reliability flags → advisor context | Server; imported as a file |
| [NASA SRTM](https://www.earthdata.nasa.gov/data/instruments/srtm) via [OpenTopoData](https://www.opentopodata.org/) | Elevation and slope → erosion risk | Downloaded once per field, cached |
| [NASA GIBS](https://www.earthdata.nasa.gov/engage/open-data-services-software/earthdata-developer-portal/gibs-api) | Map layers: MODIS NDVI, SMAP L4 root-zone soil moisture, GPM IMERG precipitation, MODIS LST | Online map tiles |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) | Base map | Online map tiles |
| FAO-56 (Allen et al., 1998) | Hargreaves reference evapotranspiration, crop coefficient approach | Method, implemented in code |
| FAO Irrigation and Drainage Paper 29 (Ayers & Westcot, 1985); Maas–Hoffman | Crop salt-tolerance thresholds (ECe) | Approximate values in the crop catalogue |
| UNEP aridity index classes | Class of the warm-season P/ET0 ratio | Method |
| [Qwen2.5-0.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF) (Apache 2.0) | Optional on-device language model | Downloaded once in the chat tab |

Crop parameters in `packages/agrofy_core/lib/data/crop_catalog.dart` are generalized reference values
chosen by the developers; they have not been reviewed by a local agronomist.

## Limitations

- Climate data is a ~50 km grid cell. Elevation is corrected with a standard
  lapse rate; slope aspect, valleys and other microclimate are not.
- The rotation engine works in monthly steps; spring and winter-crop sowing
  dates are refined to the decade from daily data, catch crops stay monthly.
- There are no built-in prices; money income requires the farmer's own prices,
  yields and costs. Second crops are assumed to yield 60% of a main-season crop.
- Scores are not calibrated automatically. Recorded yields are compared with
  the scores, but a few years cannot confirm or refute them.
- Soil salinity, groundwater and nutrients come only from the farmer; salt
  thresholds are approximate and the 10%-per-dS/m loss is an average slope.
- Tajik words and phrases were added by the developers and need a native
  speaker's review.
- Only one region profile (Sughd) exists; elsewhere a general crop list is used.
- SMAP, GPM and MODIS LST are map layers only. MODIS NDVI is used numerically
  only when a package is imported, and only as context: a 250 m pixel, not the
  field boundary.
- The SMS server has run only locally with a simulated provider. There is no
  AGROFY number or SMS provider account yet; hosting, the number and SMS costs
  are up to whoever runs the service.
- The UI is in Russian only.
- The optional language model needs iOS 16.4+, about 500 MB of storage and
  enough RAM; it has been run in the iOS Simulator only, not on a phone.

The tool supports — and does not replace — the farmer's judgment and local
agronomic expertise.

## Android

```bash
flutter build apk --release --split-per-abi
```

- `app-arm64-v8a-release.apk` (~45 MB) — modern phones, with the language model.
- `app-armeabi-v7a-release.apk` (~20 MB) — old 32-bit phones; everything works
  except the optional language model, which needs a 64-bit CPU.
- Only the llama.cpp CPU runtime is bundled (`hooks.user_defines` in
  `pubspec.yaml`); LiteRT-LM, Vulkan and WebGPU are excluded.
- Release builds are signed with the debug key and use the placeholder
  application id `com.example.agrofy_small_ai`: fine for installing directly,
  not for Google Play.
- Tested on an Android 17 (API 37) arm64 emulator: launch, schema upgrade of an
  existing install, model import from Downloads with SHA-256 check, and
  on-device generation.

## Run

```bash
flutter pub get
flutter run
```

```bash
flutter analyze
flutter test
```

143 app tests cover the scoring engine (including 3–5-year rotations and the
return-interval rule), the models, NASA response parsers (real monthly and daily
responses saved as fixtures), elevation correction, frost dates, salinity,
money income, yield calibration, model-file checks, database migrations up to
schema v8, and the observation interpreter on a 32-phrase evaluation set
(typos, synonyms, Tajik) written by the developers, SMS links and package
import (duplicates, conflicts, wrong field, ZIP, tampering). 28 server tests
(`cd server && dart test`) cover webhook signatures, replays, limits, STOP,
commands, the dialogue, package building and expiring links.

## Structure

- `packages/agrofy_core/` — pure-Dart core shared by the app and the server
  - `ai/` — year-type model, trend statistics, intent classifier, retriever,
    assistant, language-model guards
  - `decision/` — observation interpreter, evidence validator, decision engine,
    lifecycle
  - `services/` — rotation advisor, NASA POWER, MODIS and terrain clients
  - `data/` — crop catalogue, region profile, knowledge base, training examples
  - `remote/` — SMS commands and lengths, data-package format, NDVI summary
- `server/` — SMS server: webhooks, dialogue, data packages
  ([server/README.md](server/README.md))
- `lib/ai/local_llm.dart` — on-device language model (llama.cpp)
- `lib/services/` — local database, package import, SMS launcher, location
- `lib/screens/` — UI
