# PhotoTagger

A native macOS app that tags the photos in your Apple **Photos** library using a vision-language AI that runs entirely on your Mac — then writes those tags back as **Photos keywords**, so typing things like *“yellow shirt”*, *“woman in yellow”* or *“lake”* into the Photos search bar just works.

Author: **Subhaditya Mukherjee**

## What it does

- **All Photos** — a whole-library entry pinned at the top of the sidebar, for tagging everything at once.
- **Album picker** — every album and smart album in your system photo library (Recents, Favorites, your own albums, …) with photo counts.
- **Tag All** — one click runs [Qwen3-VL 8B](https://huggingface.co/mlx-community/Qwen3-VL-8B-Instruct-4bit) (4-bit) over each photo in the chosen target and adds 5–12 keywords covering the subject, clothing & colors, setting, activity and mood.
- **On-device AI** — the model runs in-process via [MLX](https://github.com/ml-explore/mlx-swift), Apple's Metal-based machine-learning framework. Nothing is uploaded anywhere; no API keys.
- **Search-ready immediately** — keywords are searchable in the Photos app's search field and visible in Get Info (⌘I). If you use iCloud Photos they sync to your other devices.
- **Never destructive** — pixels are never touched: photos are read, never edited, re-encoded or deleted. The *only* write PhotoTagger ever performs is adding keywords via Photos' additive `addKeyword` API — duplicates are ignored, existing keywords always survive.
- **Resumable** — already-tagged photos are remembered and skipped, so you can stop any run and click Tag All again later to continue (an option lets you re-tag everything if you want; even then it only merges new keywords in).

## Where the "already tagged" index lives

PhotoTagger remembers which photos it has tagged by storing their Photos `localIdentifier`s in **UserDefaults** under `PhotoTagger.taggedAssetIDs` — this persists across restarts, app updates, and re-builds (it's flushed every 25 photos, at the end of every run, and when the app goes to the background). The keywords themselves live in the Photos library, fully independent of this index.

```sh
defaults read com.phototagger.app PhotoTagger.taggedAssetIDs   # inspect it
defaults delete com.phototagger.app PhotoTagger.taggedAssetIDs # make PhotoTagger forget (keywords in Photos stay)
```

Deleting the index only means everything gets tagged again on the next run — since Photos merges keywords additively, that's harmless (just slow).

> **Note for "All Photos" on iCloud-optimized libraries:** photos whose originals aren't on this Mac are downloaded on demand during the run (one at a time), so a whole-library run may take a long while on slow connections. The Stop button and resumability make long runs painless.

## First run

1. Grant Photos access when prompted (PhotoTagger needs read-write access to add keywords; reading is what shows your albums).
2. The first **Tag All** downloads the model weights (~5.2 GB, one time) from Hugging Face into `~/.cache/huggingface` (shared with other MLX/HF tooling) and loads the model into memory (~6 GB).
3. Tagging proceeds one photo at a time — roughly 3–10 seconds per photo depending on your Mac.

## Requirements

- macOS 27+ (uses the macOS 27 Photos keyword API — `PHAssetChangeRequest.addKeyword(_:)` — which merges additively on Photos' side)
- Apple Silicon (MLX requires an M-series chip)
- Xcode 27 (to build) — on first build the script auto-downloads Xcode's Metal Toolchain component (~840 MB) if missing, since MLX compiles Metal shaders
- ~6 GB of free memory while tagging

## Building

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` (same setup as DayStream — ad-hoc code signing, hardened runtime, non-sandboxed):

```sh
./scripts/build_and_install            # Debug build → ~/Applications → launch
./scripts/build_and_install release    # Release build
./scripts/build_and_install test       # Build + run unit tests
```

The script installs XcodeGen via Homebrew on first run. The first build compiles MLX and swift-syntax and can take several minutes; subsequent builds are fast.

## How tagging works

```
Photos (PhotoKit)
   │  read photo (current version, iCloud-aware, orientation-corrected, ≤1024 px)
   ▼
Qwen3-VL 8B 4-bit (MLX, on-device)
   │  "output ONLY a comma-separated list of 5–12 tags…"
   ▼
TagParser  →  lowercase, strip junk/fillers, dedupe, cap at 12
   ▼
PHAssetChangeRequest.addKeyword(…) for each tag   (Photos merges additively —
   existing keywords are silently kept, nothing is ever removed)
```

- Videos are skipped (counted in the progress UI).
- A fresh chat session is used per photo so no tags leak between images.
- Tag output is heavily sanitized before it reaches your library (see `Sources/AI/TagParser.swift`, covered by unit tests).

## Model download integrity

The ~5.2 GB of weights come from the Hugging Face hub into `~/.cache/huggingface` (shared with other HF/MLX tooling). Two hard-won rules protect the app around this download:

1. **MLX crashes (traps) on incomplete weight files** rather than throwing a catchable error. A download interrupted by an app quit leaves a partial snapshot in the cache, and naively loading it takes the whole app down.
2. **Hub repos can be internally inconsistent** — `mlx-community/Qwen3-VL-8B-Instruct-4bit`'s `model.safetensors.index.json` references shard names from an older upload than the safetensors files actually in the repo. The weights themselves are fine; the index is stale, and MLX's loader ignores it via its conventional-name fallback.

So `ModelStore` does its own lifecycle: download → **validate** (every `*.safetensors` the repo's git tree lists must be present at the exact expected byte size, and each file's safetensors header must parse) → load. If validation fails, the repo's cache directory is wiped and the download retried once; a second failure surfaces as a readable error instead of a crash. There is deliberately no "load from cache without network" fast path — that API can return partial snapshots.

## Verifying a build

```sh
# unit tests (tag parser)
./scripts/build_and_install test

# end-to-end: downloads/loads the model, tags one image, logs the tags, exits 0
build/Build/Products/Debug/PhotoTagger.app/Contents/MacOS/PhotoTagger \
    -selfTestImage /path/to/any/photo.jpg
```

The self-test prints the raw model answer, the parsed tags, the inference time, and the memory footprint to the console log (`log show --predicate 'process == "PhotoTagger"' --last 5m`).

## Design decisions

- **Photos keywords as the tag store.** Keywords are searchable directly in Photos' search bar (the whole point of the app), sync over iCloud Photos, and survive on every device. Descriptions/titles are never touched.
- **The macOS 27 `addKeyword` API.** Photos merges keyword additions additively on its side — duplicates are silently ignored and existing keywords can't be lost. There is no read-modify-write of the keyword list anywhere in this app (macOS doesn't even expose reading `PHAsset.keywords`).
- **In-process MLX over a server.** No Ollama/LM Studio sidecar, no Python venv — the model runs inside the app via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) on Apple's MLX, which is the most optimized path on Apple Silicon (Metal, unified memory, per-layer 4-bit quantization).
- **One fresh `ChatSession` per photo.** Prevents any tag leakage between photos through conversation history; the expensive part (the 5.4 GB `ModelContainer`) is loaded once per app run.
- **Resumability via a local tagged-photo set** (`UserDefaults`, flushed periodically), so Tag All is safe to click repeatedly and interrupted runs pick up where they left off. iCloud-only photos are fetched on demand via PhotoKit's network access.
- **Vision budget.** Photos are decoded to ≤1024 px and the Qwen3-VL processor caps at its default ~1,280 vision tokens — plenty for descriptive tagging at a fraction of the compute.

## Searching your new tags

Open Photos and just type in the search bar — `lake`, `yellow shirt`, `birthday party`, `sunset`. Keywords also appear (and can be filtered by) in **Get Info** ⌘I. In Photos settings you can manage the keyword list under **Settings → General → Manage Keywords** (hiding a keyword there only affects the Info window, not search).

## Project structure

```
Sources/
  App/        App entry point, central app model / run loop, in-app debug log, self-test hook
  Photos/     PhotoKit service (albums, image loading, keyword writes), tagged-asset store
  AI/         Model download/load/validate (MLX + Hugging Face hub), hub bridges, tagging engine, tag parser
  Views/      Album picker, album detail, live run view, debug pane, model status footer
Tests/        Tag parser unit tests
scripts/      build_and_install (auto-installs Xcode's Metal toolchain on first run)
```

## Privacy notes

- The model and all inference are local; your photos never leave the machine.
- The only photo-library mutation is *adding* keywords via PhotoKit.
- The tagged-photo index lives in `UserDefaults` on this Mac only — see "Where the 'already tagged' index lives" above for how to inspect or clear it.

## Troubleshooting

- **In-app debug log** — the sidebar has a hidden *Developer → Debug Log* section. Reveal it with **View ▸ Show Debug Panel (⇧⌘D)**. It records every error and warning live (model load failures, per-photo failures with the asset id, Photos write retries, tag-parse misses), with a red badge on the sidebar row counting errors since the last clear. Use *Copy All* to export the log as text; every entry is also mirrored to the console (`log show --predicate 'process == "PhotoTagger"' --last 15m`).
- **“Model produced no usable tags”** — the VLM sometimes drops the commas and answers with a plain run of tag words ("family boat trip ocean sunny"). The tag parser detects that shape and salvages the individual words as keywords (linking words like "in"/"with" are filtered, prose answers are left alone), so these photos now tag normally instead of failing.
- **“Photos rejected the keyword change: Photos error NNNN (…)”** — the number identifies the cause: `3300 changeNotSupported` / `3306 requestNotSupportedForAsset` usually mean the photo is read-only in Photos (shared iCloud albums) — those are now skipped automatically and never retried; `3301 operationInterrupted` is transient and retried once; `3307 limitExceeded` retries with a trimmed tag set; `3164 networkAccessRequired` / `3169 networkError` mean the iCloud original couldn't be fetched — the photo is counted failed and picked up on a later run. Every failure is also written to the console log: `log show --predicate 'process == "PhotoTagger"' --last 15m`.
- **“The model download was incomplete … The cached copy was cleared”** — a transient network failure. Just click Tag All again; the app wipes the bad cache and re-downloads. Weights live in `~/.cache/huggingface/hub/models--mlx-community--Qwen3-VL-8B-Instruct-4bit` (~5.4 GB) if you ever want to reclaim the space.
- **Download seems stuck** — the big shard (4.9 GB) buffers into a hidden `CFNetworkDownload_*.tmp` file under `/var/folders/.../T/` before materializing in the cache, so cache size can sit still for minutes while bytes flow. Give it time on slow links (~10 min at 10 MB/s).
- **“Could not load the AI model”** — check free disk space and that `huggingface.co` is reachable.
- **Photos access denied** — System Settings → Privacy & Security → Photos → enable PhotoTagger, then hit Retry in the app.
- **Ad-hoc signing note** — as with any locally ad-hoc signed app, macOS may re-ask for Photos permission after a fresh install replaces the bundle.
- **First photo is slower** — the first inference includes Metal kernel compilation; later photos run at full speed (~3–10 s each depending on Mac).
