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
- Builds 3-, 4- or 5-year rotations, keeps alfalfa as a multi-year block and
  never brings the same crop back sooner than three years.
- Corrects temperature for the field's elevation relative to the NASA grid
  cell and gives frost dates with probability and sowing dates to the decade
  from daily NASA POWER data.
- Takes salinity, groundwater depth and soil nutrients from the farmer and
  checks crops against FAO salt-tolerance thresholds.
- Shows income in money when the farmer enters prices, yields and costs, and
  compares recorded yields with the advisor's score for the same year.
- Turns a plain-language field observation ("leaves are yellowing, soil is
  dry") into structured facts with sources, flags missing data and
  contradictions, and proposes a cautious next step with a plan.
- Tracks the crop through eight lifecycle stages and keeps a field timeline.
- Works over plain SMS when there is signal but no data: the app opens the
  phone's SMS app with a prepared question or data request, and an AGROFY SMS
  server answers with the same decision engine, or sends a link to a NASA data
  package (MODIS NDVI or NASA POWER daily climate) for that field. The farmer
  imports the file; the app checks its checksum, units, field and duplicates,
  and shows NDVI as context, not as a diagnosis.
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
6. Over SMS (optional server, `server/`): a signed webhook from the SMS
   provider reaches the server, which runs the same pure-Dart core and replies
   within 3 SMS segments. Data requests are fetched from MODIS MOD13Q1 (ORNL
   DAAC web service) and NASA POWER, packed as JSON with a SHA-256 checksum and
   linked by a random token that expires in 7 days.
7. Optionally, Qwen2.5-0.5B-Instruct (4-bit GGUF, llama.cpp) runs on the phone
   and adds a two-sentence note in plain language. The exact answer stays
   visible, and the note is discarded if it introduces a number not present in
   the facts, goes off topic or leaves Russian.

Stack: Flutter / Dart, SQLite (sqflite), flutter_map, llamadart (llama.cpp).
The three core models are pure Dart and add no download; the language model is
an optional 491 MB download.

### Validity and limitations
- 143 app tests and 28 server tests cover scoring, the models, the language-model guards,
  the observation interpreter (32-phrase evaluation set written by the team),
  validator, decision rules, lifecycle, NASA response parsing (real responses
  saved as fixtures), frost dates, salinity, income, calibration, database
  migrations, SMS webhook signatures, replays, limits, STOP, the SMS dialogue
  and package import (duplicates, conflicts, wrong field, tampering).
- The SMS server was run locally with a simulated provider against the live
  NASA services: it produced a real MODIS NDVI package for a point near
  Khujand, which was then imported in the Android emulator. No real SMS number
  or provider exists yet.
- The observation rules were written by the team, are intentionally limited to
  "measure / check / consult", and have not been reviewed by an agronomist.
- The language model has been run in the iOS Simulator only; its Russian is
  imperfect, which is why it never replaces the exact answer.
- Verified in the iOS Simulator with real NASA data for a field near Khujand.
- Not yet validated against measured yields or reviewed by an agronomist; crop
  parameters are generalized reference values chosen by the team.
- Climate is a ~50 km grid cell; elevation is corrected, other microclimate is
  not. The engine works in monthly steps; sowing dates are refined to decades.
- No built-in prices: money income needs the farmer's own numbers. Soil data
  comes from the farmer; salt thresholds are approximate.
- SMAP, GPM and MODIS LST appear as map layers only. MODIS NDVI is used
  numerically only from an imported package, as context; one 250 m pixel is
  not the field boundary.

### Benefits
- Works where connectivity is poor; field data stays on the phone.
- Shows water demand per strategy in mm and m³ per hectare.
- Makes uncertainty visible: results per year type, listed data gaps, and
  explicit prompts to consult local expertise.

### Goals and next steps
- Agronomist review of crop parameters for Sughd.
- Tajik and English interfaces.
- Use recorded yields from the crop-lifecycle log to calibrate scores.
- Run the SMS server with a local operator or aggregator and a real number.
- Numeric use of SMAP soil-moisture anomalies; NDVI over the field polygon
  rather than one pixel.
- More region profiles.

### Tools and technologies
- Flutter, Dart
- sqflite, flutter_map, latlong2, geolocator, http, path_provider
- llamadart / llama.cpp with Qwen2.5-0.5B-Instruct (GGUF)
- NASA POWER API, NASA GIBS, OpenTopoData (SRTM), ORNL DAAC MODIS web service
- SMS server: Dart, shelf, Docker; Vonage, Twilio or any HTTP SMS gateway

## NASA Data

- **NASA POWER** (https://power.larc.nasa.gov/) — climatology and 1991–2025
  monthly series of temperature, temperature range, precipitation, frost days
  and root-zone soil wetness. Feeds the water balance, sowing windows, year-type
  model and trends. Daily minimum and mean temperature (1991–2025) feed frost
  dates and sowing to the decade; the grid-cell elevation feeds the elevation
  correction.
- **SRTM** elevation (https://www.earthdata.nasa.gov/data/instruments/srtm) —
  elevation and slope of the field; feeds the erosion-risk term.
- **MODIS Terra NDVI (16-day)** via NASA GIBS — vegetation layer on the map.
- **MODIS Terra Vegetation Indices MOD13Q1 v061** (250 m, 16-day,
  https://lpdaac.usgs.gov/products/mod13q1v061/) through the ORNL DAAC MODIS
  web service (https://modis.ornl.gov/data/modis_webservice.html) — the field's
  NDVI series with pixel reliability, delivered as a data package over SMS and
  shown in the advisor as context.
- **NASA POWER daily** T2M, T2M_MIN and PRECTOTCORR for a recent period —
  climate data packages sent through the SMS channel.
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
- FAO Irrigation and Drainage Paper 29 (Ayers & Westcot, 1985) and
  Maas–Hoffman — approximate crop salt-tolerance thresholds.
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
- On the SMS server, the optional `/ВОПРОС` command sends a farmer's free
  question with the field's NASA-based data (not the phone number) to a
  language model: Qwen2.5-1.5B-Instruct (Apache 2.0) run on the server with
  llama.cpp, whose answers are checked and declined when unreliable, or Claude
  through the Anthropic API if the operator configures a key.
  Its answers are labelled as a language model's answer; every other SMS
  answer comes from the rule-based engine.
- No AI-generated images or video are used. [TODO: update if the demo uses any;
  they would need a visible watermark.]

## Demo and links

- Demo (video ≤ 30 s with English subtitles, or ≤ 7 slides): [TODO: public link]
- Final project (public repository): https://github.com/khusravB/agrofy-small-ai
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
