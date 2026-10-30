# Photo replay harness

Runs the app's **real** photo path on a folder of photos and writes what the app
would have logged for each one, so the result can be compared with another log
(MacroFactor's, say) meal by meal, without tapping through the app.

What runs is the app's own code, not a copy: the photo interpreter
(`ModelMealPhotoInterpreter` over the OpenAI-compatible client, "a server you
run"), `ReadMealPhotoUseCase`, `BulkAddBloc`, `ResolveParsedMealsUseCase`
(database match first, AI-estimate fallback, grams defaults, the dish row), and
the same row maths the review screen uses. The bloc is driven headless with
`ReadMealPhotoEvent`; nothing in the app was changed to allow it.

## Privacy rules

Photos are private. The harness is built so that none of the following can
happen, and anything added to it must keep it so:

- **Never commit photos** to this public repo, and never upload them as an
  artifact. They live in the private `darpna/ont-testdata` repo only.
- **Never print or write a file name or path.** A name can hold a date or a
  place. A photo is identified by `id`: the first ten characters of the SHA-1 of
  its bytes. Progress lines say `[3/20] a9993e3647 …` and nothing more.
- The keys (`REPLAY_API_KEY`, or `GROQ_API_KEY` as before, and
  `REPLAY_FALLBACK_API_KEY`) are read from the environment, held in memory, and
  never printed.
- Captions in the output are the text of the sidecar files the owner wrote.

## Differences from the app

- **Image encoding** is done in Dart (`dart_photo_preparer.dart`), because the
  app's encoder is a platform plugin that does not exist under `flutter test`.
  Same recipe: EXIF orientation applied, shortest edge scaled to 1024 px (never
  enlarged), JPEG at quality 80 (the format the app sends to a server you run),
  no metadata. The pixels differ slightly from the native encoder's.
- **HEIC** cannot be decoded in Dart. The private-repo workflow converts it to
  JPEG first; run locally, convert it yourself (`heif-convert`).
- **Food search** is Open Food Facts only, with no local data: the fork has no
  Supabase backend configured and a replay should not depend on a phone's own
  foods or cache.
- The country boost on search results follows the machine's locale, as it does
  on a phone.

## Run it locally

```sh
REPLAY_DIR=/path/to/photos \
REPLAY_OUT=replay.json \
REPLAY_API_KEY=… \
  flutter test tool/replay/replay_test.dart
```

`REPLAY_DIR` is searched recursively for `.jpg`, `.jpeg` and `.png`; a file
`<name>.txt` beside `<name>.jpg` is that photo's caption. Optional:
`REPLAY_BASE_URL` (default `https://api.groq.com/openai/v1`), `REPLAY_MODEL`
(default `qwen/qwen3.8-27b`), `REPLAY_MIN_GAP_SECONDS` (default `20`),
`REPLAY_RUNS` (default `1`: how many times every photo is read, to see whether
the answers agree), and the fallback the app asks when the primary times out,
answers 429 or answers 5xx: `REPLAY_FALLBACK_BASE_URL`, `REPLAY_FALLBACK_MODEL`
and `REPLAY_FALLBACK_API_KEY` (off unless the first two are set). With a
fallback set, the primary's 429 is not retried by the harness, so the replay
shows the app handing it to the fallback. One food-number cache is shared by the
whole run, as a phone keeps one.

It needs network access to the API and to Open Food Facts, and the usual
codegen first (`just build`, with a `.env` as in `AGENTS.md`). Without
`REPLAY_DIR` or the key the test skips and says why.

**Pacing.** Groq's free tier allows 30 requests and 8K tokens a minute and an
image costs about 2,000 tokens, so requests are spaced 20 seconds apart (three a
minute, counting any second request a photo triggers). A `429` waits for the
provider's `Retry-After` (capped at two minutes) and retries up to three times.
A run of 20 photos takes about seven minutes.

## Output

`REPLAY_OUT` holds:

```json
{
  "model": "gemini-3.5-flash",
  "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
  "runs": 1,
  "fallback_model": "qwen/qwen3.8-27b",
  "fallback_base_url": "https://api.groq.com/openai/v1",
  "photos": [
    {
      "id": "a9993e3647",
      "caption": "katsu chicken wrap, 250 g",
      "dish": "Katsu chicken wrap",
      "items": [
        {
          "name": "breaded fried chicken",
          "source": "db",
          "db_name": "Chicken, fried",
          "grams": 120.0,
          "kcal": 300.3,
          "protein_g": 25.0,
          "carbs_g": 10.0,
          "fat_g": 18.0,
          "estimated": true
        }
      ],
      "unmatched": ["katsu sauce"],
      "total_kcal": 300.3,
      "error": null,
      "http_status": null,
      "provider_error": null,
      "portion_g": 250.0,
      "confidence": "medium",
      "grounded": { "grams": 250.0, "kcal": 540.2, "protein_g": 28.1, "carbs_g": 61.0, "fat_g": 19.4 },
      "ai_only": { "grams": 250.0, "kcal": 515.0, "protein_g": 27.0, "carbs_g": 58.0, "fat_g": 18.0 },
      "run": 1,
      "model_used": "gemini-3.5-flash",
      "dishes": [
        {
          "name": "Katsu chicken wrap",
          "portion_g": 250.0,
          "servings": 1.0,
          "confidence": "medium",
          "assumptions": ["Added fat capped at 8% of the dish: 30 g to 20 g."],
          "grounded": { "grams": 250.0, "kcal": 540.2, "protein_g": 28.1, "carbs_g": 61.0, "fat_g": 19.4 },
          "ai_only": { "grams": 250.0, "kcal": 515.0, "protein_g": 27.0, "carbs_g": 58.0, "fat_g": 18.0 },
          "rows": [
            {
              "name": "Chicken, breaded, fried",
              "source": "db",
              "db_name": "Chicken, broilers or fryers, breast, meat and skin, cooked, fried, batter",
              "grams": 120.0,
              "per100g": { "kcal": 260.0, "protein_g": 24.8, "carbs_g": 9.0, "fat_g": 13.2 },
              "kcal": 312.0,
              "protein_g": 29.8,
              "carbs_g": 10.8,
              "fat_g": 15.8
            }
          ]
        }
      ],
      "primary_error": null,
      "primary_http_status": null,
      "primary_provider_error": null
    }
  ]
}
```

- `items` are the rows the app **would have logged** (resolved, not skipped, no
  amount the app would hold back). `source` is `db` or `ai_estimate`; `db_name`
  is null for the latter. `estimated` is true while the amount is the model's.
- `dish` is set when the photo was read as one composed dish; its components are
  then the first `items`.
- `unmatched` lists foods the model named that nothing could stand in for.
- `error` is a failure kind (`transient`, `auth`, `providerError`,
  `unreadable`, …). `unreadable` means the photo could not be encoded; a
  provider that answered with an HTTP error is never reported as that. For
  those, `http_status` and `provider_error` (always present, null otherwise) carry the status and the
  provider's error text (cut to 200 characters, key-shaped strings masked), so
  a bad key, a rate limit and a bad photo can be told apart.
- `grounded` is the dish total the app shows: the sum of the ingredients with
  the bundled USDA table's numbers where it matched. `ai_only` is the same
  ingredients (same grams) with only the model's numbers. Comparing the two over
  a set of photos shows whether the table helps. `portion_g` and `confidence`
  are the model's. All four are null when nothing was read or the photo was not
  read as a recipe.
- `source` is `db` for an ingredient the table matched, `ai_estimate` for one
  that kept the model's numbers.
- `dishes` is every dish the photo was read as, each with its own `grounded`
  and `ai_only` totals, its assumptions (the model's, then a line for every
  check in code that changed something) and its `rows`: every ingredient with
  `source` `db` (the table), `cache` (the numbers settled the first time that
  food came up) or `ai` (the model's, checked), and its `per100g`.
- With several dishes, the older top-level fields describe the whole plate:
  `dish` is the first dish's name, `portion_g`, `grounded` and `ai_only` are
  sums over the dishes, and `confidence` is the lowest of them.
- `run` is which reading of the photo this is (from 1); with `runs` above 1
  each photo appears once per run. `model_used` is the model that answered:
  the primary's, or the fallback's when the primary failed.
- `primary_error`, `primary_http_status` and `primary_provider_error` are set
  when the fallback answered: the primary's failure kind, its HTTP status and
  its error text (as for `provider_error`), so a photo the fallback read still
  says why the primary did not. All three are null when the primary answered.
- `dish`, `unmatched`, `portion_g`, `confidence`, `grounded`, `ai_only`, `run`,
  `model_used`, `dishes` and the `primary_*` fields are additions to the
  minimal shape.

The file is rewritten after every photo (into `<REPLAY_OUT>.tmp`, then renamed
over `REPLAY_OUT`), always in the shape above, so a run that is cancelled or
times out leaves a complete file with every photo read so far. The workflow
uploads it whatever the outcome of the replay step.

## In the private repo

`ont-testdata-replay.yml` is the workflow for `darpna/ont-testdata`, copied to
`.github/workflows/replay.yml` there. It is inert in this repo (not under
`.github/workflows`).

1. Photos go in `photos/<day>/` (optional `<name>.txt` captions beside them).
2. Add the repository secrets `GEMINI_API_KEY` and `GROQ_API_KEY`.
3. Actions → **Replay photos** → Run workflow; `day` is a folder name or `all`.
   The other inputs default to Gemini (`gemini-3.5-flash` on Google's
   OpenAI-compatible endpoint) with Groq (`qwen/qwen3.8-27b`) as the fallback,
   and one run; `key_secret` and `fallback_key_secret` name the secrets to use,
   and an empty `fallback_base_url` turns the fallback off.
4. Download the `replay` artifact (`replay.json`). Artifacts of a private
   repository are private.

The workflow checks out the public app at ref `darp`, installs the Flutter
version `app/.fvmrc` pins, runs codegen, converts HEIC to JPEG in a scratch
folder, runs the harness, and uploads only `replay.json`.

## Tests

The parts that need no network (ids, file discovery, output shape, pacing,
retry, the transport) are covered by `test/unit_test/replay_harness_test.dart`
and `test/unit_test/replay_photo_preparer_test.dart` in the normal test run. The
harness itself is not run in CI.
