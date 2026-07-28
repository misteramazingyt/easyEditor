# EasyEditor

A private iOS **video editor** with a Final Cut Pro–style **magnetic timeline**
in a mobile-first layout: preview on top, layered timeline under the playhead,
and a TikTok-style tool row (Media · Music · Title · SFX · Voice · Text).

All original code — the TikTok-editor *feature set* is reimplemented from
scratch in Swift/SwiftUI + AVFoundation. Nothing is extracted from any
third-party app binary.

---

## The timeline

```
titles   ▄            (purple, 1/5 primary height — Title & Text clips)
images   ▄▄           (1/3 primary height — connected stills)
b-roll   ▄▄▄          (1/2 primary height — connected video, covers storyline)
PRIMARY  ▄▄▄▄▄▄▄▄▄▄▄  (magnetic storyline: filmstrip clips, no gaps ever)
voice    ▄▄           (voiceover + SFX)
music    ▄▄▄▄▄        (green, FCP style)
```

- The playhead is **fixed at center**; drag the timeline to scrub, pinch to zoom.
- The primary storyline is **magnetic**: clips ripple to close gaps; drag a
  clip horizontally to reorder (light snap ticks as the insertion point moves).
- **Long-press and drag a clip vertically to move it between layers** — you
  feel a medium **haptic each time it crosses into another lane**, and a rigid
  tap when it drops. Video moves between primary ↔ b-roll; audio between
  voice ↔ music.
- Tap a clip to select (FCP yellow border + trim handles), tap again for the
  inspector. The small square between storyline clips opens the
  **transition picker**.

## Editor features (TikTok-editor parity, original implementation)

| Area | Details |
|---|---|
| Clips | trim (ripple), split at playhead, duplicate, delete, reorder |
| Speed | 0.3×–3× per clip, pitch-corrected audio |
| Audio | per-clip volume/mute, music import (Files), voiceover recording, synthesized SFX library |
| Look | 10 filters (Core Image), brightness/contrast/saturation, rotate, flip |
| Transitions | dissolve, fade-to-black, slide L/R, zoom, per-boundary duration |
| Text | Titles + captions on the purple lane, font size/color/plate, position/scale/opacity |
| Images | connected stills with placement controls |
| Canvas | 9:16 / 16:9 / 1:1, letterboxed |
| Export | H.264 MP4 via the same custom compositor as the preview, saved to Photos |

The preview and the export share one rendering path (a custom
`AVVideoCompositing` implementation), so what you scrub is what you ship.

---

## Status

This repository contains the **complete Swift/SwiftUI source**, structured for
XcodeGen. It must be **built on macOS with Xcode** — it cannot compile on
Windows/Linux. The code was authored on Windows, so do a clean build + device
test pass before relying on it.

Requirements:
- macOS + **Xcode 15+**
- iPhone running **iOS 17+**
- An Apple Developer signing identity (free personal team is fine for local
  installs)

## Building

### CI (GitHub Actions)
Every push to `main` builds an **unsigned .ipa** on a macOS runner and uploads
it as the `EasyEditor-unsigned-ipa` artifact (see `.github/workflows/build.yml`).
Sign/install it with your usual sideloading tool (AltStore, Sideloadly, etc.).

### Locally
```bash
brew install xcodegen
xcodegen generate
open EasyEditor.xcodeproj
```
Then select the **EasyEditor** target → Signing & Capabilities → choose your
Team, pick your iPhone, and ⌘R.

---

## Architecture

```
EasyEditor/
  EasyEditorApp.swift        App entry (dark theme)
  AppState.swift             Project library store
  EditorState.swift          Per-session state: undo stack, selection, zoom,
                             debounced save + composition rebuild
  Models/
    Models.swift             Lanes, filters, transitions, text styles, placement
    TimelineClip.swift       One clip anywhere on the timeline
    VideoProject.swift       Magnetic storyline math (derived start times)
  Services/
    ProjectStore             Codable JSON in Documents
    MediaImportService       PhotosPicker/Files import into per-project media dirs
    ThumbnailService         Filmstrip thumbnails (AVAssetImageGenerator)
    OverlayRenderer          Text/images → CIImage (shared by preview + export)
    CompositionEngine        Project → AVMutableComposition + instructions
    LayeredCompositor        Custom AVVideoCompositing: filters, transitions,
                             b-roll layering, overlay stamping
    PlaybackController       AVPlayer wrapper (30 Hz time, coalesced seeks)
    ExportService            AVAssetExportSession → MP4
    PhotoLibraryService      Save to Photos (add-only)
    VoiceRecorder            AVAudioRecorder voiceovers
    SFXLibrary               WAV synthesis — no bundled binary audio
  Views/
    ProjectListView          Library grid
    EditorView               Top bar, preview, transport, timeline, tool row
    Timeline/                TimelineView (lanes, drags, haptics), ClipChipView
    ToolbarView              Media/Music/Title/SFX/Voice/Text tiles
    Sheets/                  Inspector, transitions, text, SFX, voice, export
  Utilities/                 Logger, FilePaths, Haptics, TimeFormat
```

### Engine notes
Primary clips alternate across two composition video tracks so transitions can
overlap; every b-roll/audio clip gets its own track. The timeline is tiled
into instruction intervals at every clip/transition/overlay boundary, and each
instruction carries per-layer opacity/transform ramps plus filter settings for
the custom compositor. Speed uses `scaleTimeRange` with pitch-corrected audio.

## Privacy
Everything is on-device. The app makes **no network calls at all**.
