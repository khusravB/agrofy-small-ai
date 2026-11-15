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
(`lib/ai/llm_grounding.dart`). A 0.5B model writes imperfect Russian, so treat
the note as a convenience, not as advice. Without the model the app works
exactly the same, minus the note.

## Decision pipeline for field observations

The "Observations" tab follows a strict separation of responsibilities:
the AI understands the input, a validator checks the evidence, deterministic
rules decide, and the result is explained as a plan.

| Layer | Code | Responsibility |
|---|---|---|
| Interpreter | `lib/decision/observation_interpreter.dart` | Free text → structured facts, each with a source and a status (observed / inferred / unknown) |
| Evidence validator | `lib/decision/evidence_validator.dart` | Missing data, contradictions between the farmer, the journal, measurements and NASA climate; never picks a side |
| Decision engine | `lib/decision/decision_engine.dart` | Reproducible rules → a decision code such as `verifySoilMoisture`; asks for a measurement rather than prescribing when evidence is thin |
| Recommendation and plan | same file | Action, reason, evidence, missing information, three alternatives, expected outcome, status, action steps |
| Crop lifecycle | `lib/decision/crop_lifecycle.dart` | Eight stages, forward-only transitions, each logged to the field journal |
| Field memory and outcomes | `lib/decision/saved_observation.dart` | Stored observations; a later observation is compared with the earlier recommendation without claiming causality |

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
- **Year types** — every strategy is scored in dry, normal and wet years.
- **Farmer priorities** — sliders for water, soil, income and weather resilience.
- **"What if" scenario** — rainfall and temperature sliders.
- **Field conditions** — irrigation method losses, soil texture, pH, SRTM slope.
- **Regional tuning** — crops typical for Sughd, second crops after winter cereals.
- **Offline assistant** — chat that answers from the field's own data.
- **Map** — NASA GIBS layers (MODIS NDVI, SMAP soil moisture, GPM IMERG rainfall,
  MODIS land-surface temperature) and field markers coloured by water stress.
- **Knowledge base** — 22 short offline articles explaining the terms.
- **Observations** — describe what you see in plain words; get extracted facts
  with sources, missing data, contradictions, a recommendation and a plan.
- **Crop lifecycle** — eight stages with controlled transitions, stored locally.
- **Field memory** — timeline of observations, irrigations and stage changes.

## Data

| Source | Used for | Access |
|---|---|---|
| [NASA POWER](https://power.larc.nasa.gov/) climatology and monthly history | Temperature, rainfall, frost days, root-zone soil wetness; water balance, sowing windows, year types, trends | Downloaded once per field, cached in SQLite |
| [NASA SRTM](https://www.earthdata.nasa.gov/data/instruments/srtm) via [OpenTopoData](https://www.opentopodata.org/) | Elevation and slope → erosion risk | Downloaded once per field, cached |
| [NASA GIBS](https://www.earthdata.nasa.gov/engage/open-data-services-software/earthdata-developer-portal/gibs-api) | Map layers: MODIS NDVI, SMAP L4 root-zone soil moisture, GPM IMERG precipitation, MODIS LST | Online map tiles |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) | Base map | Online map tiles |
| FAO-56 (Allen et al., 1998) | Hargreaves reference evapotranspiration, crop coefficient approach | Method, implemented in code |
| [Qwen2.5-0.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF) (Apache 2.0) | Optional on-device language model | Downloaded once in the chat tab |

Crop parameters in `lib/data/crop_catalog.dart` are generalized reference values
chosen by the developers; they have not been reviewed by a local agronomist.

## Limitations

- Climate data is a ~50 km grid cell; a field's microclimate is not captured.
- Calculations use monthly steps, so sowing dates are accurate to the month.
- Market value is a 1–5 index, not local prices; yields and costs are not modelled.
- Scores are for comparing options with each other and are not calibrated
  against measured yields.
- Salinity, groundwater level and nutrient status are not in the data.
- Rotations are three years with one main crop per year; perennial alfalfa is
  simplified.
- Only one region profile (Sughd) exists; elsewhere a general crop list is used.
- SMAP, GPM and MODIS are shown as map layers; the numeric analysis uses
  NASA POWER and SRTM.
- The UI is in Russian only.
- The optional language model needs iOS 16.4+, about 500 MB of storage and
  enough RAM; it has been run in the iOS Simulator only, not on a phone.

The tool supports — and does not replace — the farmer's judgment and local
agronomic expertise.

## Run

```bash
flutter pub get
flutter run
```

```bash
flutter analyze
flutter test
```

Tests cover the scoring engine, the three models, the NASA response parsers
(with real responses saved as fixtures) and database migrations up to schema v6, plus the observation
interpreter (a 16-phrase evaluation set), validator, decision rules and lifecycle.

## Structure

- `lib/ai/` — year-type model, trend statistics, intent classifier, retriever, assistant
- `lib/decision/` — observation interpreter, evidence validator, decision engine, lifecycle, field memory
- `lib/services/rotation_advisor.dart` — rotation scoring and explanations
- `lib/services/` — NASA POWER client, terrain client, local database
- `lib/data/` — crop catalogue, region profile, knowledge base, training examples
- `lib/screens/` — UI
