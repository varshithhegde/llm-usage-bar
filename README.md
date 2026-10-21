# LLM Usage Bar

A native macOS menu bar app (SwiftUI, macOS 14+) that tracks LiteLLM AI gateway spend and usage.

## Build & run

```sh
./build.sh               # release build → build/LLM Usage.app (ad-hoc signed)
./build.sh --selftest    # also runs offline self-tests
./build.sh --install     # also copies the app to ~/Applications
open "build/LLM Usage.app"
```

Only the Command Line Tools are needed (Swift Package Manager, no Xcode project).

Open the menu bar icon → **Settings** → paste your LiteLLM key → **Save** / **Test connection**.
The key is stored in the macOS Keychain (service `dev.varshith.LLMUsageBar`). If the Keychain
has no key, the app falls back to the `LITELLM_API_KEY` environment variable.

## Data

Everything is stored in `~/Library/Application Support/LLMUsageBar/usage.sqlite`:

- `daily`: one row per day (metrics plus per-model, per-key and per-provider breakdown as JSON), upserted by date
- `snapshots`: lifetime spend for the user and each key, recorded on every refresh
- `cache`: last raw `/user/info`, `/key/info`, `/v1/models` responses, shown right away at launch
- `meta`: backfill and endpoint-availability flags

The first run backfills `/user/daily/activity` from your account's `created_at`. Later refreshes only refetch the last 3 days.
If the daily endpoint returns 403/404, daily spend comes from differences between snapshots instead (history only starts from first launch, and there is no per-model breakdown).

Settings also has **Export CSV** and **Reset local data**.

Day buckets use UTC so they match LiteLLM.

## Desktop pet

A floating Pokémon that shows your spend. Set it up in Settings → Pet (pick a Pokémon, shiny, size, opacity,
bubble text, click-through), or use the paw button in the popover footer.

- Drag to move. Hover to see a stats card. Click to open the popover. Right-click for a menu.
- Mood is today's spend compared to your daily alert threshold (if set) or your average over the previous 7 days.
  The pet bounces when excited, and glows red and shakes when overheated.
- Sprites download from the PokeAPI sprites repo at runtime (none are included in this repo) and are cached in
  `~/Library/Application Support/LLMUsageBar/sprites/`.
- Debug: `LLMUSAGEBAR_PET_SNAPSHOT=/path/pet.png "build/LLM Usage.app/Contents/MacOS/LLMUsageBar"` saves a picture of the pet window as a PNG.
