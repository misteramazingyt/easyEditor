# EasyEditor handoff — the staggered outro block

**Date:** 2026-07-23
**Audience:** the Claude instance working in the EasyEditor Xcode project.
**Status:** nothing on the app side is built yet. The three media assets are
staged in `outro-assets/` in this folder. This document specifies the feature.

The ask, in one sentence: **one tap appends the house outro to the end of the
timeline as a group of clips that behave like a single object** — tap any one
of them and all are selected; delete or drag one and they all go together.

---

## 1. What the outro looks like

It is a *staggered* build, not a single clip. Four elements enter at four
different moments, which is the whole point — the music arrives before
anything visibly happens, so the viewer is caught off guard.

```
lane                     …existing storyline…│  outro
─────────────────────────────────────────────┼──────────────────────────
+2  animation (screen)              ┌────────────────────┐
+1  ink matte (multiply)      ┌───────────┐
PRIMARY  storyline  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄│███████ black ███████
−2  music sting            ┌──────────────────────────┐  (long fade in)
                                             ▲
                                             T = end of existing storyline
```

Read left to right: the sting fades up under the tail of the video → black
ink floods the picture from a corner → as the ink is still spreading the
retro logo animation begins screening over it → the ink completes into a
plain black canvas → the animation finishes over that black as though it had
never been blended at all.

This mirrors the reference render (`0816.mp4`) frame for frame; the timings
in §3 were measured off it, not guessed.

---

## 2. The assets

Staged in `outro-assets/`, ready to add to the Xcode target as bundle
resources (~4.6 MB total):

| file | what | notes |
|---|---|---|
| `ink-flood-matte.mp4` | 1920×1080, 61 frames, 2.03 s | Grayscale. **White = keep the picture, black = ink.** Transcoded from a 72 MB ProRes original — do not re-import that one. |
| `retro-animation.mp4` | 1080×1920, 3.48 s | The MISTER AMAZING logo build on black. Portrait-native. |
| `retro-sting.mp3` | 10.16 s | Hanna-Barbera "Swirling Star". **Only the tail is used** — trim in at 6.00 s. |

Bundle them (Xcode → target → *Build Phases → Copy Bundle Resources*, or add
a `resources:` entry to `project.yml`). On first use, copy each into the
project's media directory so the existing clip plumbing works unchanged:

```swift
let dst = FilePaths.mediaURL(projectID: project.id, fileName: "outro-ink.mp4")
if !FileManager.default.fileExists(atPath: dst.path),
   let src = Bundle.main.url(forResource: "ink-flood-matte", withExtension: "mp4") {
    try FileManager.default.copyItem(at: src, to: dst)
}
```

The black canvas is **generated, not bundled** — write a 1×1 (or canvas-sized)
opaque black PNG into the media directory at build time, so it is correct for
whatever `project.aspect` is set to. A `.image` clip letterboxes to the canvas
anyway, so a solid black PNG of any aspect works; generate it canvas-sized to
keep the inspector honest.

---

## 3. The schedule

Let **T** = the end of the existing primary storyline *before* the outro is
added (i.e. `project.totalDuration` at the moment the user taps the button).

| element | lane / stack | starts | duration | notes |
|---|---|---|---|---|
| music sting | `.music` (−2) | **T − 2.68** | 4.16 s | trim 6.00 → 10.16; fade in over 1.8 s |
| ink matte | connected **+1** | **T − 1.60** | 2.03 s | blend **multiply**; rotate 90° in portrait |
| retro animation | connected **+2** | **T − 0.81** | 3.48 s | blend **screen** |
| black canvas | **primary** | **T** | 2.75 s | ordinary storyline clip appended last |

Derived moments worth knowing (do not hard-code these; they fall out of the
table): the ink first becomes *visible* at **T − 0.98** — its first 0.62 s is
a white head that multiplies invisibly — and it reaches full black at exactly
**T**, which is why the black canvas begins there. The animation starts five
frames after the ink becomes visible.

The outro therefore **overlaps the last 1.6 s of existing content**, which is
what makes it a transition rather than an append. If a user wants to lose
nothing, they can freeze-frame or extend their final clip first; that is their
call, not the builder's.

Total added length: **T + 2.75**, i.e. about 2.75 s longer than the original.

### Audio

The sting is deliberately quiet — in the reference it sits **−14.3 dB** under
the programme. Set `volume ≈ 0.19` (10^(−14.3/20)) on the music clip.

The reference also sweeps a low-pass filter open as the sting rises, so it
surfaces from behind the narration rather than cutting in. EasyEditor has no
per-clip EQ today. **Ship without it** — the 1.8 s fade carries most of the
effect — and only revisit if it sounds abrupt on device. Do not build an EQ
subsystem for this one cue.

---

## 4. Engine work required

Three pieces. Two are genuinely new capabilities the app lacks; the third is
the feature itself.

### A. Clip linking (`groupID`) — *this is the part the user actually asked for*

Nothing in the codebase groups clips today. Add an optional group identifier
and make the three edit paths group-aware.

**Model** (`Models/TimelineClip.swift`) — optional so existing saved projects
still decode:

```swift
/// Clips sharing a groupID select, move, and delete as one unit.
var groupID: UUID?
```

**Project helper** (`Models/VideoProject.swift`):

```swift
/// Every clip linked to `id`, including `id` itself.
func linkedClips(with id: UUID) -> [TimelineClip] {
    guard let clip = clip(id), let group = clip.groupID else {
        return clip.map { [$0] } ?? []
    }
    return clips.filter { $0.groupID == group }
}
```

**Editor** (`EditorState.swift`) — three call sites:

1. `deleteClip(_:)` currently does `project.remove(id)`. Remove the whole
   group instead:
   ```swift
   func deleteClip(_ id: UUID) {
       pushUndo()
       for c in project.linkedClips(with: id) { project.remove(c.id) }
       if selectedClipID == id { selectedClipID = nil }
   }
   ```
2. **Selection** — when a clip with a `groupID` is tapped, every member should
   draw the FCP yellow border. `selectedClipID` is a single `UUID?`; rather
   than widening it everywhere, add a derived set the timeline reads:
   ```swift
   var selectedClipIDs: Set<UUID> {
       guard let selectedClipID else { return [] }
       return Set(project.linkedClips(with: selectedClipID).map(\.id))
   }
   ```
   Then in `Views/Timeline/ClipChipView.swift`, drive the border from
   `state.selectedClipIDs.contains(clip.id)` instead of the `==` check.
   Trim handles should still show only on the tapped clip — trimming one
   member of a staggered group must not resize the others.
3. **Dragging** — a horizontal drag on any member moves all members by the
   same delta, preserving the stagger. Connected members move by `offset`;
   the storyline member (the black canvas) reorders magnetically. The
   simplest correct rule: **if a group contains a primary-storyline clip,
   only allow the group to be dragged as a storyline reorder**, and shift
   every connected member's `offset` by the resulting change in that clip's
   magnetic start time. Vertical (cross-lane) drags should be **rejected for
   grouped clips** — the stagger depends on the lane assignment, and there is
   no sensible meaning to moving the whole group up one lane.

Ungrouping is worth a line in the clip inspector (*Ungroup* → clears
`groupID` on every member), so the user can break the block apart and hand-
tune it without fighting the linking.

### B. Blend modes

`CompositingSettings` is drop-shadow/glow/outline styling — there is **no
blend mode in the app at all**, and this outro needs two. Add:

```swift
enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal, screen, multiply, overlay, add
    var id: String { rawValue }
    var ciFilterName: String? {
        switch self {
        case .normal:   return nil
        case .screen:   return "CIScreenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .overlay:  return "CIOverlayBlendMode"
        case .add:      return "CIAdditionCompositing"
        }
    }
}
```

with `var blend: BlendMode?` on `TimelineClip` (optional, defaults to
`.normal`).

**Where it applies** — `Services/LayeredCompositor.swift`, the connected-clip
loop, currently ends each layer with:

```swift
result = image.cropped(to: canvas).composited(over: result)
```

Replace with a blend-aware composite:

```swift
let cropped = image.cropped(to: canvas)
if let filterName = (layer.blend ?? .normal).ciFilterName {
    result = cropped.applyingFilter(filterName,
                                    parameters: [kCIInputBackgroundImageKey: result])
                    .cropped(to: canvas)
} else {
    result = cropped.composited(over: result)
}
```

You will need to carry `blend` onto whatever layer struct the compositor
builds from the clip (same place `compositing`, `opacity` and `focus` are
carried), and the same for the export path — but `LayeredCompositor` *is* the
shared path for preview and export, so one change covers both.

> **A warning worth heeding.** When this outro was built for the desktop
> pipeline, screen-blending was first done in YUV and it tinted the *entire
> video* magenta — screening chroma planes whose neutral is 128 pushes them to
> 191. Core Image blend filters work in RGB, so you do not inherit that bug —
> but if you ever push this through an `AVMutableVideoComposition` shortcut or
> a YUV pixel path, check a mid-grey frame for a colour cast before trusting it.

Two consequences for the outro:

- **Ink = multiply.** White multiplies to a no-op (picture untouched), black
  multiplies to black (ink). That is exactly the matte semantics, with no
  keying code required.
- **Animation = screen.** Black screens to a no-op, so the logo build floats
  over the ink and then sits on the black canvas looking unblended.

### C. The builder + the entry point

New service, `Services/OutroBuilder.swift`:

```swift
enum OutroBuilder {
    /// Appends the staggered outro to `project`. All four clips share one
    /// groupID so the timeline treats them as a single object.
    static func appendOutro(to project: inout VideoProject) throws
}
```

Behaviour:

1. Copy the three bundled assets into the project media directory (idempotent
   — reuse if already present) and generate the black canvas PNG.
2. `let T = project.totalDuration` **before** appending anything.
3. `let group = UUID()`, then build the four clips per the §3 table, each with
   `groupID = group`:
   - **black** — `.image` on `.primary`, appended last so it becomes the final
     storyline clip; `trimEnd = 2.75`.
   - **ink** — `.video`, `lane: .broll`, `laneIndex: 1`, `offset: T - 1.60`,
     `blend: .multiply`, `isMuted = true`, and
     `rotationQuarterTurns = (project.aspect == .portrait916) ? 1 : 0`.
   - **animation** — `.video`, `lane: .broll`, `laneIndex: 2`,
     `offset: T - 0.81`, `blend: .screen`, `isMuted = true`.
   - **sting** — `.music`, `lane: .music`, `offset: T - 2.68`,
     `trimStart: 6.0`, `trimEnd: 10.16`, `volume: 0.19`, plus a 1.8 s fade-in.
4. Guard the edge case: if `T < 2.68` the sting would start before zero. Clamp
   every start to `max(0, …)` and accept the shortened lead rather than
   refusing to build.

**Entry point.** Put it on the tool row as *Outro* (alongside Media · Music ·
Title · SFX · Voice · Text), or — probably better — in the existing sheet that
handles project-level actions, since it is a once-per-video action rather than
a tool. One tap, no configuration sheet: the block lands at the end, the
playhead jumps to `T - 2.68` so the user immediately sees what happened, and
undo removes all four clips as one (it already will, since `pushUndo()`
snapshots the whole project).

---

## 5. Aspect-ratio caveat

The retro animation is **portrait-native (1080×1920)**. In a 9:16 project it
fills the canvas exactly. In 16:9 or 1:1 it will letterbox to fit — the logo
will be small and centred. That is acceptable for now; if landscape outros
become routine, the right fix is a second landscape master of the animation
rather than any code change.

The ink matte is the opposite (landscape master, rotated one quarter-turn for
portrait) and covers the canvas in either orientation.

---

## 6. Acceptance checks

Build it, then verify on device:

1. **Grouping.** Tap the black clip → all four highlight. Drag it → all four
   move, stagger intact. Delete → all four vanish. Undo → all four return.
2. **Colour.** Scrub to 1 s before the outro and screenshot. Nothing should be
   tinted; the picture must look identical to the same frame with the outro
   removed. (This is the magenta trap from §4B.)
3. **The stagger.** With audio on, the sting should be audible *before*
   anything moves on screen. If the ink starts first, the offsets are wrong.
4. **The ink.** The picture should darken from a corner, not cross-fade. If
   you see a dissolve, `blend` is not reaching the compositor.
5. **The finish.** The final second is the logo animation on flat black, with
   no ghost of the underlying video.
6. **Export parity.** Export and compare against the preview at the same
   timestamps — preview and export share `LayeredCompositor`, so any
   divergence means `blend` was wired into one path and not the other.

---

## 7. What is deliberately not in scope

- **The low-pass sweep on the sting** (§3) — needs a per-clip EQ the app does
  not have, for one cue.
- **Configurable timings.** The stagger is the house look; exposing sliders
  invites drift. If it needs tuning, tune the constants in `OutroBuilder`.
- **An intro counterpart.** Same machinery would serve one, but no intro
  design exists yet — do not generalise ahead of it.
