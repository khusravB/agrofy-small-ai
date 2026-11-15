# NASA Space Apps 2026 — submission draft

Challenge: **Field Shift: Adapting Farms with NASA Data**

Items marked [TODO] must be filled in by the team. Nothing below is submitted
until the team pastes it into the Space Apps form.

## Project Name

AGROFY Small AI — crop-rotation advice that works without a signal

## High-Level Summary

Near Khujand, Tajikistan, rain covers about 23% of what the atmosphere can
evaporate (297 mm against 1,306 mm a year, NASA POWER), and farmers who grow
cotton year after year pay for it in water and in tired soil. Most of them also
work where mobile coverage is unreliable, so cloud-based advice is not there
when a decision is made.

AGROFY Small AI is a phone app and decision-support tool that combines NASA
Earth observations with local soil information, crop characteristics and farmer
priorities to help farmers explore rotation strategies. It compares the existing
rotation with three alternatives and, for each, explains why it was suggested,
what evidence supports it, what benefits it may offer, where information gaps
exist and which risks need local review. A small model trained on the phone
sorts 35 years of the field's own weather into dry, normal and wet years and
tests every rotation in each. A second small model powers an offline question
assistant that answers only from the field's data and names its source; an
optional 0.5B language model on the phone adds a plain-language note.

NASA data is downloaded once per field; after that the advisor, the models and
the assistant run with no network and no data leaving the phone. The tool
supports the farmer's judgment and local agronomists rather than replacing
them. Next: review of crop parameters by agronomists in Sughd, Tajik and
English interfaces, and calibration against recorded yields.

## Detailed Description

### What it does
- Compares the current rotation with three alternatives: water saving, soil
  building, income and resilience.
- Scores each on water, soil health, pest-cycle disruption, income and weather
  resilience, weighted by sliders the farmer sets.
- Shows each strategy's result in dry, normal and wet years.
- Flags bare-field months, the driest months, frost months and significant
  climate trends for the field.
- Offers a "what if" scenario with rainfall and temperature sliders.
- Answers questions offline in a chat tab ("What should I plant after cotton?",
  "What if there is a drought?").
- Shows NASA map layers (NDVI, soil moisture, rainfall, surface temperature)
  and colours field markers by water stress.
- Explains terms such as evapotranspiration, NDVI and soil-moisture anomalies
  in a 22-article offline knowledge base.

### How it works
1. The farmer adds a field (coordinates, crop, soil type, pH, irrigation method).
2. With a connection, the app downloads NASA POWER climatology and 1991–2025
   monthly history for that point, and SRTM elevation around it, and stores
   them in a local SQLite database.
3. On the device:
   - reference evapotranspiration is computed with the Hargreaves equation
     (FAO-56) from temperature and latitude;
   - for each crop the engine finds the best sowing window and its water
     balance (crop coefficient × ET0 against effective rainfall, adjusted for
     soil texture and irrigation losses);
   - k-means clustering groups the years into three types; Theil–Sen and
     Mann–Kendall statistics estimate trends;
   - candidate three-year rotations are scored, with cover crops and second
     crops placed in bare months, and each chosen strategy is replayed in every
     year type.
4. Explanations are generated from the same numbers, so every statement can be
   traced to data.
5. In the chat, a naive Bayes classifier identifies the question's intent and a
   BM25 retriever finds knowledge-base articles; the reply is assembled from
   advisor results.
6. Optionally, Qwen2.5-0.5B-Instruct (4-bit GGUF, llama.cpp) runs on the phone
   and adds a two-sentence note in plain language. The exact answer stays
   visible, and the note is discarded if it introduces a number not present in
   the facts, goes off topic or leaves Russian.

Stack: Flutter / Dart, SQLite (sqflite), flutter_map, llamadart (llama.cpp).
The three core models are pure Dart and add no download; the language model is
an optional 491 MB download.

### Validity and limitations
- 59 automated tests cover scoring, the models, the language-model guard, NASA
  response parsing (real responses saved as fixtures) and database migrations.
- The language model has been run in the iOS Simulator only; its Russian is
  imperfect, which is why it never replaces the exact answer.
- Verified in the iOS Simulator with real NASA data for a field near Khujand.
- Not yet validated against measured yields or reviewed by an agronomist; crop
  parameters are generalized reference values chosen by the team.
- Climate is a ~50 km grid cell and calculations use monthly steps.
- Market value is a 1–5 index, not prices. Salinity, groundwater and nutrients
  are not in the data.
- SMAP, GPM and MODIS appear as map layers; the numeric analysis uses NASA
  POWER and SRTM.

### Benefits
- Works where connectivity is poor; field data stays on the phone.
- Shows water demand per strategy in mm and m³ per hectare.
- Makes uncertainty visible: results per year type, listed data gaps, and
  explicit prompts to consult local expertise.

### Goals and next steps
- Agronomist review of crop parameters for Sughd.
- Tajik and English interfaces.
- Use recorded yields from the crop-lifecycle log to calibrate scores.
- Numeric use of SMAP soil-moisture anomalies and NDVI time series per field.
- More region profiles.

### Tools and technologies
- Flutter, Dart
- sqflite, flutter_map, latlong2, geolocator, http, path_provider
- llamadart / llama.cpp with Qwen2.5-0.5B-Instruct (GGUF)
- NASA POWER API, NASA GIBS, OpenTopoData (SRTM)

## NASA Data

- **NASA POWER** (https://power.larc.nasa.gov/) — climatology and 1991–2025
  monthly series of temperature, temperature range, precipitation, frost days
  and root-zone soil wetness. Feeds the water balance, sowing windows, year-type
  model and trends.
- **SRTM** elevation (https://www.earthdata.nasa.gov/data/instruments/srtm) —
  elevation and slope of the field; feeds the erosion-risk term.
- **MODIS Terra NDVI (16-day)** via NASA GIBS — vegetation layer on the map.
- **SMAP L4 Analyzed Root Zone Soil Moisture** via NASA GIBS — soil-moisture
  layer on the map.
- **GPM IMERG Precipitation Rate** via NASA GIBS — rainfall layer on the map.
- **MODIS Terra Land Surface Temperature (Day)** via NASA GIBS — heat-stress
  layer on the map.

## Space Agency Partner & Other Data

- No partner-agency datasets are used.
- OpenTopoData (https://www.opentopodata.org/) — public API serving SRTM 30 m.
- OpenStreetMap (https://www.openstreetmap.org/copyright) — base map, ODbL.
- FAO Irrigation and Drainage Paper 56 — Hargreaves ET0 and crop-coefficient
  method.
- Qwen2.5-0.5B-Instruct-GGUF
  (https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF) — Apache 2.0,
  optional on-device language model.
- Open-source packages: Flutter, sqflite, flutter_map, latlong2, geolocator,
  http, path_provider, llamadart (see `pubspec.yaml`).

## Use of AI

- Claude (Anthropic), through Claude Code, wrote most of the application code,
  tests and this draft under the team's direction. The team reviewed the
  results and tested the app in the iOS Simulator.
- [TODO: confirm] ChatGPT / Codex was used earlier to produce the project
  brief.
- Inside the app: k-means, naive Bayes and BM25 are trained or built on the
  device and are not generative. An optional small generative model,
  Qwen2.5-0.5B-Instruct (Alibaba Cloud, Apache 2.0), runs on the phone to
  rephrase answers; its text is labelled in the chat and checked against the
  computed facts.
- No AI-generated images or video are used. [TODO: update if the demo uses any;
  they would need a visible watermark.]

## Demo and links

- Demo (video ≤ 30 s with English subtitles, or ≤ 7 slides): [TODO: public link]
- Final project (public repository): [TODO: link]
- Team name and members: [TODO]

Suggested 30-second video:
0:00 team and challenge → 0:05 name and tagline → 0:08 airplane mode on, open
the field → 0:12 strategies and dry-year results → 0:20 ask the assistant
"What if there is a drought?" → 0:25 NDVI layer on the map → 0:28 impact line.

## Before submitting

- [ ] All fields filled, in English
- [ ] Every link opens in a private window without login
- [ ] Demo within limits, English subtitles or slides
- [ ] AI use confirmed and complete
- [ ] No personal information in screenshots
- [ ] All team members registered at the same Local Event
- [ ] Both checkboxes ticked, then "Submit for Judging" clicked
