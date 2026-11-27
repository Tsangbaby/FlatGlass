# FlatGlass 1.8.4 — reconstructed source tree

Package `local.lumid.flatglass` 1.8.4+diag.2, a diagnostic of the 1.8.4 build.
This is a repaired reconstruction from
the release binaries, not the author's original source or an installable
package. It retains the four components and their notify chain.

---

## What is in the box

| Path | What it is |
|---|---|
| `FlatGlassIconServices/` | The renderer. Injects `iconservicesagent`, replaces two IconServices methods, rebuilds icons. |
| `FlatGlassRefresh/` | Injects `SpringBoard`. Reloads visible icon views after a mode change. |
| `flatglass/` | LaunchDaemon. Reads the preference, publishes the notify state, renders theme bundles. |
| `FlatGlassPrefs/` | Preference bundle. Mode picker + localized strings (en, ru). |
| `Shared/` | Preference keys, notify names, layout constants, logging. |
| `tools/` | Build staging helper and Mach-O / ObjC analysis utilities. |

---

## How the pieces talk to each other

```
Settings pane
  writes CFPreferences "Mode"
  posts  local.lumid.flatglass.settings-changed
        │
        ▼
flatglass daemon  (--watch)
  notify_set_state(iconservices-mode, Mode + 1)
  notify_post(iconservices-mode)
        ├──────────────────────────────┐
        ▼                              ▼
FlatGlassIconServices            FlatGlassRefresh
(iconservicesagent)              (SpringBoard)
  re-renders the icon              waits 2 s
  clears the icons cache           walks SBIconImageView
  writes .flatglass-mode           reloads 4 at a time, 25 ms apart
```

The `+1` reserves state 0 for an unset or disabled daemon and maps the four
saved modes to states 1–4. Republishing an unchanged mode does not change its
state value.

Mode values are **not** in display order — this trips people up:

| Label | `Mode` | Published state |
|---|---|---|
| Remove Highlights | 0 | 1 |
| Edge and Artwork | 1 | 2 |
| Off | 2 | 3 |
| Edge Only | 3 | 4 |

### RootHide diagnostic D2

D2 does not repair rendering. It retains the existing launchctl command and
fallback order, renderer hooks, production notify lifetime, refresh route and
cache actions. D2 uses its own diagnostic channels and file names, does not
touch a D1 report, and uploads no data.

- `/var/mobile/Documents/FlatGlassDiagnostics-d2-install.plist` is written
  independently of the watcher by a short-lived installer probe that drops to
  `mobile` before touching either directory. It falls back to the same basename
  under `/var/mobile/Library/Preferences/` if Documents cannot be written.
  `install_phase` 1 means the pre-launchctl probe ran, and 2 means launchctl
  returned. `bootstrap_status`/`fallback_status` are command exit statuses,
  with `-1` for not attempted. A successful launchctl call is not daemon proof.
- The watcher tries `/var/mobile/Documents/FlatGlassDiagnostics-d2.plist` and
  `/var/mobile/Library/Preferences/FlatGlassDiagnostics-d2-preferences.plist`
  independently before registering the diagnostic agent channels. `phase` 1
  is the early snapshot, and 2 means diagnostic subscriptions were attempted.
  `documents_write_status` and `preferences_write_status` describe the **first**
  attempts: `-1` unobserved, `0` saved and read back, `1` invalid arguments,
  `2` directory open, `3` directory identity, `4` file open, `5` file identity,
  `6` lock, `7` truncate, `8` write/sync, `9` readback, `10` close. They are
  not receipts for later snapshots. The sequence is capped at 64 snapshots per
  daemon start. Files are private (0600); no directories are created. A read
  concurrent with a rewrite can be incomplete.

- `initial` and `change` retain the startup and last settings-change publish
  attempts, including register/set/cancel/post return codes. `0` status is
  success, not an acknowledgement by a consumer. `changes` counts observed
  publisher callbacks, not user taps. `watch_status` describes the subscription.
- `agent_flags` is cumulative within the report, with separate bit ranges for
  startup and notification reads and their marker outcomes (see `FGDiagnostics.h`).
  `startup_read` and `notification_read` are summaries: `0` is an observed zero,
  `-1` is no successful read observed, `-2` is mixed or other. The raw bits also
  distinguish a reported read failure from no event. Hook acceptance means at
  least one original install gate passed, not evidence of rendered pixels.
- `terminal_cache_write_failed` records a failure notification sent immediately
  before the existing process exit. `terminal_flags` can also carry its coarse
  read context. The two channel statuses describe collector registration, not
  the sender's delivery. The writer replaces a bounded snapshot, not an event
  history. Across agent restarts bits may describe different invocations.

For a single reproduction, install D2, switch between the two Edge modes once,
return to the Home Screen and export whichever of the above files appear in
Filza. No cache clear, terminal command or respring is required for this test.
Check file freshness after a repeated D2 install; a prior diagnostic file may
still exist when the present write fails. Missing reports are not proof a process
did not run. A process can exit before the asynchronous watcher report is written,
and missing agent events alone cannot distinguish no delivery from no load.

---

## Building

Requires [Theos](https://theos.dev), an iPhoneOS SDK and toolchain that can
build `arm64` and `arm64e` for the declared iOS 15.0 deployment target, and
Python 3 for the staging helper.

```sh
export THEOS=/path/to/theos
# Choose one scheme. Clean before switching schemes.
make clean THEOS_PACKAGE_SCHEME=rootless && make package THEOS_PACKAGE_SCHEME=rootless
# Or:
make clean THEOS_PACKAGE_SCHEME= && make package THEOS_PACKAGE_SCHEME=
# With roothide/theos, build the separate RootHide package:
make clean THEOS_PACKAGE_SCHEME=roothide && make package THEOS_PACKAGE_SCHEME=roothide
```

The default is rootless (`/var/jb`, package architecture `iphoneos-arm64`).
An empty scheme selects rootful (no prefix, `iphoneos-arm`). RootHide emits
`iphoneos-arm64e` metadata and uses the RootHide bootstrap's virtual root and
launchctl path handling. The macOS Actions workflow builds only RootHide on
this test branch. A successful build does not establish device compatibility.

---

## What was recovered exactly, and what was not

Honesty matters more than a nice-looking file tree, so here is the real state.

### Contracts documented by the reconstruction

- **The two hook points and their guard.** `ISAssetCatalogResource` and
  `ISCompositor` `-imageForSize:scale:` are validated before swapping:
  4 arguments, `@` return, `{CGSize=dd}` argument 2, `d` argument 3. If any check
  fails the tweak installs nothing and logs one line. See `FGCompat.m:FGIsImageRenderer`.
- **Catalog layout.** ISTC header offsets `0xa8` (record region length) and
  `0xb4` (payload length), record region at `0xb8`, TLV records of
  `{u32 id, u32 len, bytes}`.
- **Layer records.** Id 1012 = layer (flags, frame, blend mode, opacity, keyList
  at `+0x20`), 1020 = group, 1021 = fill.
- **Rendition selection.** keyList matching then appearance-token `7`, with the
  untagged and first-match fallbacks.
- **Gradient parsing.** Three payload headers (`ARGG` 0x20 with explicit
  start/end points, `ARGA` 0x14, `ARGN` 0x10), then repeated
  `{float stop, u32 nameLen, char name[]}`.
- **The flatten operation.** This is the whole "Remove Highlights" mode:
  ```c
  lum = B*0.0722 + G*0.7152 + R*0.2126 + 0.5;   // Rec.709
  lum = min(lum, 255);
  v   = min(lum, alpha);
  B = G = R = v;
  ```
  Weights are the constants at `__TEXT:0x10b58/0x10b60/0x10b68`.
- **Element drawing.** Offscreen alpha-only mask, bounding box at threshold 9,
  `CGContextClipToMask`, then fill through it.
- **Sizing.** `ceil(scale * max(w, h))`, clamped to 16…1024.
- **Cache invalidation.** Stamp file `.flatglass-mode`, format `1:<state>`,
  icon cache at `/private/var/containers/Shared/SystemGroup/…/com.apple.IconsCache`,
  and the `_exit(0)` when the stamp cannot be written.
- **Single-colour gradient synthesis.** The 0.25 / 0.5 / 0.75 luminance branches
  and the `-0.2` contrast constant.

### Structurally equivalent, parameters re-derived

- **`IGCreateIconShape`** produces the right silhouette (continuous-corner
  rounded rect, radius ≈ 22.4 % of the edge). The original walks a 15-value
  control table at `__TEXT:0x10d30`; those constants are listed in `FGShape.m`
  as `kFGSquirclePoints` and the path code below them is the standard Bézier
  construction, not a literal transcription of the original loop.
- **`IGDrawChicletHighlights`** — the pipeline is right (distance field from the
  silhouette, diagonal specular sweep, 22 px falloff, optional artwork pass),
  the exact shading constants are approximated. Output looks close, is not
  bit-identical.
- **`IGDrawGroup`** — plain source-over compositing; the original has extra
  blend modes behind flags that are never set by this tweak.
- **`NGCreateRimmedImage` / `NGCreateGlassedImage`** — the edge detection and
  highlight ordering match; the rim intensity (0.55) and artwork gain are tuned
  values, not extracted ones.

### Not ported

- The daemon's SnowBoard theme generation (`--gloss-icon`, `--preview-scan`)
  is implemented against `CUICatalog` / `LSApplicationWorkspace` but the theme
  bundle writer is simplified: it renders and reports, it does not emit the
  full `IconBundles` tree the original produces.
- `FlatGlass.svg` and the preview PNGs are shipped as resources but the preview
  header in the settings pane is not drawn.

The private catalog reader still uses reconstructed storage and rendition
lookups; it has not been shown to match the release's catalog enumeration or
stack matching on a device. The approximated render passes also prevent a
claim of pixel-identical output.

---

## Debugging on device

The legacy debug logging below is separate from the D2 export. It is not needed
for the D2 device test.

```sh
# enable logging in the icon agent
launchctl setenv FLATGLASS_DEBUG 1
killall -9 iconservicesagent
log stream --predicate 'eventMessage CONTAINS "[FlatGlass]"'

# see what the daemon published
notifyutil -g local.lumid.flatglass.iconservices-mode

# inspect the cache stamp
cat /private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache/.flatglass-mode

# list apps whose icons can be rendered
/var/jb/usr/libexec/flatglass --preview-scan

# remove generated themes and clear the mode
/var/jb/usr/libexec/flatglass --disable
```

`IG_STEPS` (default 32) controls the highlight sweep resolution in
`IGDrawChicletHighlights`.

---

## Working on a new version

```sh
ar x com_nx_*.deb                     # or dpkg-deb -R
python3 tools/analyze.py path/to/Binary > dis.txt
```

`tools/analyze.py` annotates every `bl` with its symbol, resolves chained-fixup
import stubs, and labels selectors, C strings and CFStrings. `tools/macho.py`
parses fat/thin Mach-O including `LC_DYLD_CHAINED_FIXUPS`.

Function addresses quoted throughout the source refer to the **arm64 slice** of
1.8.4. On a new build, re-run the tool and diff the symbol table first — the
layout of the compositor has been stable, the ISTC record ids have not changed
since iOS 13, but the private class names in `FGCompat.m` are the first thing to
re-check (`ISAssetCatalogResource`, `ISCompositor`, `IFImage`, `ISiOSAppRecipe`).

---

## Known constraints

- `Depends: mobilesubstrate` is required for injection (ElleKit also works).
- `preferenceloader` is required for the settings pane to appear.
- The renderer checks the two hook signatures before replacing them. This
  guard is not a compatibility or stability guarantee for other private APIs.

---

## Repair verification

```sh
python3 -B -m unittest discover -s tests -v
```

The tests check source contracts, plist wiring, all three scheme layouts and
maintainer-script routing with `launchctl` replaced by a test double. The
render hooks, SVG geometry and ownership changes were checked against the
disassembly from the original reconstruction archive; the tests do not run
UIKit, IconServices or CoreSVG.

See the Actions run for the exact commit's compile, link and package result.
SnowBoard theme export and release-equivalent visual output are outside this
repair, and behavior on a real device still needs testing.
