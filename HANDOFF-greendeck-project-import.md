# Handoff: receive GreenDeck projects in EasyEditor

**From:** the GreenDeck Claude Code chat (`D:\Inbox\00 Now\202606261024 - GreenDeck`)
**Date:** 2026-07-29
**Task for this chat:** make EasyEditor receive a `.gdproj` package sent from
GreenDeck via the iOS share sheet, and turn it into a `VideoProject` with the
clips on the primary storyline in the packaged order.

---

## What GreenDeck now does (already implemented and shipped)

GreenDeck (green-screen recorder, `com.greendeck.app`) lets the user group
recorded segments into a "project" and tap **Send to EasyEditor**. That:

1. Builds a flat staging directory:
   ```
   manifest.json
   clip-001.mp4
   clip-002.mp4
   ...
   ```
   Clips are H.264/AAC MP4s (1080×1920 or 720×1280 portrait), already numbered
   in the intended storyline order (the order they were recorded).
2. Archives the directory's contents with **Apple Archive** (`AppleArchive`
   framework, **lzfse**, field key set `TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM`)
   into a single file named `<Project Name>.gdproj`.
   ⚠️ It is an Apple Archive, **not a zip** — chosen because iOS has no public
   unzip API and we control both apps. Sender code:
   `GreenDeck/Services/ProjectHandoffService.swift` in the GreenDeck repo.
3. Presents a `UIActivityViewController` with that file. GreenDeck's Info.plist
   exports the UTI `com.greendeck.project` for extension `gdproj`
   (conforms to `public.data`).

## The manifest contract (version 1)

`manifest.json`, ISO-8601 dates:

```json
{
  "format": "greendeck-project",
  "version": 1,
  "name": "My Project",
  "exportedAt": "2026-07-29T18:00:00Z",
  "clips": [
    {
      "fileName": "clip-001.mp4",
      "duration": 12.4,
      "recordedAt": "2026-07-29T17:31:02Z",
      "notes": "optional user note, may be absent"
    }
  ]
}
```

Rules:
- **Storyline order = array order** (file numbering matches, but trust the array).
- `duration` is advisory — re-probe with `AVURLAsset` on import (you already do
  this in `MediaImportService.importVideoFile`).
- Reject `format != "greendeck-project"`. For `version > 1`, import what you
  understand or show a friendly "update EasyEditor" alert — don't crash.
- `notes` may be missing; ignore unknown extra keys (future versions may add
  some).

## What EasyEditor needs (implementation checklist)

### 1. Declare the imported type (project.yml → `info.properties`)

EasyEditor already uses an explicit `info:` block in `project.yml`, so add:

```yaml
CFBundleDocumentTypes:
  - CFBundleTypeName: GreenDeck Project
    LSHandlerRank: Owner
    LSItemContentTypes: [com.greendeck.project]
UTImportedTypeDeclarations:
  - UTTypeIdentifier: com.greendeck.project
    UTTypeDescription: GreenDeck Project
    UTTypeConformsTo: [public.data]
    UTTypeTagSpecification:
      public.filename-extension: [gdproj]
```

Do **not** set `LSSupportsOpeningDocumentsInPlace` (leave absent/false): the
system then copies the file into `Documents/Inbox/`, which is exactly what we
want — consume it and delete it.

### 2. Receive the file

In `EasyEditorApp`, attach `.onOpenURL { url in ... }` to the root view and
route `pathExtension == "gdproj"` to a new import service. No security-scoped
access is needed for `Documents/Inbox` files, but calling
`startAccessingSecurityScopedResource()` defensively is harmless.

### 3. Extract (mirror of the sender)

```swift
import AppleArchive
import System

func extract(_ archive: URL, to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let readStream = ArchiveByteStream.fileStream(
            path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []),
          let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream),
          let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream),
          let extractStream = ArchiveStream.extractStream(
            extractingTo: FilePath(dir.path), flags: [.ignoreOperationNotPermitted])
    else { throw ImportError.badArchive }
    defer { try? readStream.close() }
    defer { try? decompressStream.close() }
    defer { try? decodeStream.close() }
    defer { try? extractStream.close() }
    _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
}
```

Extract to a temp dir (`FilePaths.tempDirectory`), read `manifest.json`
(`JSONDecoder` with `.iso8601` dates).

### 4. Build the VideoProject

- `AppState.createProject(name: manifest.name)` (it already de-dups nothing —
  duplicate names are fine in your model).
- For each manifest clip **in array order**: the extracted file is already on
  disk, so `MediaImportService.importVideoFile(extractedURL, projectID:
  project.id, deleteSource: true)` → on `.video(fileName:duration:)`, append a
  `TimelineClip(kind: .video, lane: .primary, fileName: fileName,
  assetDuration: duration, trimEnd: duration, order: project.nextPrimaryOrder)`
  — match however your Photos-picker import path constructs primary clips so
  trim/order invariants hold (see `EditorState` media import).
- Skip clips whose file is missing or probes to zero duration; count them.
- `AppState.save(project)`; then clean up: delete the extraction dir **and the
  Inbox `.gdproj` file**.

### 5. UX

- If `ProjectListView` is on screen, the new project should appear at the top
  (AppState insert-at-0 already does this). Ideally show a toast/alert:
  "Imported <name> — N clips" (+ "M clips skipped" when applicable), and it's
  fine to just land the user in the project list rather than auto-opening the
  editor.
- Failure alert on: bad archive, missing/unparseable manifest, wrong `format`,
  zero importable clips.

### 6. Test plan (with the GreenDeck side)

1. Build both apps (each repo's GitHub Actions `build.yml` produces an unsigned
   IPA artifact), sideload both on the same device.
2. In GreenDeck: record 2–3 short segments → Segments → Edit → select → New
   Project → Projects → **Send to EasyEditor** → share sheet → EasyEditor.
3. Verify: project appears in EasyEditor with the clips in recorded order,
   correct durations, playable in the editor, exportable.
4. Re-send the same project: should create a second project (no dedup
   required for v1).

## Coordination notes

- Any change to the manifest schema or archive settings must be coordinated
  with the GreenDeck repo (`ProjectHandoffService.swift` + this doc) and bump
  `version`.
- GreenDeck targets iOS 17.0, EasyEditor too — AppleArchive is iOS 14+, fine.
- Both apps are sideloaded unsigned; that's why the transfer uses the share
  sheet + document type instead of app groups (unavailable) or a URL scheme
  with no payload channel.
