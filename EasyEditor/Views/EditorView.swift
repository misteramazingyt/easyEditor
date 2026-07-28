import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The main editing screen: preview on top, magnetic timeline below,
/// TikTok-style tool row at the bottom.
struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: EditorState

    @State private var pickedMedia: [PhotosPickerItem] = []
    @State private var showMusicImporter = false
    @State private var showTextSheet = false
    @State private var textSheetIsTitle = true
    @State private var showSFXSheet = false
    @State private var showVoiceSheet = false
    @State private var showExportSheet = false
    @State private var showInspector = false
    @State private var showFullscreen = false
    @State private var transitionAfterClipID: UUID?
    @State private var activeTool: ClipTool?
    @State private var showTimelinePicker = false
    @State private var showMediaMenu = false
    @State private var showWebSearch = false

    init(project: VideoProject) {
        // The save closure is wired to AppState in .onAppear via the
        // environment; the StateObject needs a stable initial closure, so we
        // route through a shared box.
        let box = SaveBox()
        _editor = StateObject(wrappedValue: EditorState(project: project) { box.save?($0) })
        saveBox = box
    }

    private let saveBox: SaveBox
    final class SaveBox { var save: ((VideoProject) -> Void)? }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            transportBar
            TimelineView(transitionAfterClipID: $transitionAfterClipID,
                         showInspector: $showInspector,
                         onAddMedia: { showTimelinePicker = true },
                         onAddSound: { showMusicImporter = true })
                .environmentObject(editor)
            if editor.selectedClipID != nil {
                SelectedClipToolbar(activeTool: $activeTool,
                                    transitionAfterClipID: $transitionAfterClipID)
                    .environmentObject(editor)
            } else {
                ToolbarView(
                    onMedia: { showMediaMenu = true },
                    onMusic: { showMusicImporter = true },
                    onTitle: { textSheetIsTitle = true; showTextSheet = true },
                    onSFX: { showSFXSheet = true },
                    onVoice: { showVoiceSheet = true },
                    onText: { textSheetIsTitle = false; showTextSheet = true },
                    onCaptions: { editor.generateCaptions() })
            }
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
        .onAppear {
            saveBox.save = { appState.save($0) }
            Haptics.prepare()
        }
        .onChange(of: pickedMedia) { _, items in
            guard !items.isEmpty else { return }
            editor.importPickedMedia(items)
            pickedMedia = []
        }
        .fileImporter(isPresented: $showMusicImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                editor.importMusic(from: url)
            }
        }
        .sheet(isPresented: $showTextSheet) {
            TextEditorSheet(isTitle: textSheetIsTitle) { payload, placement in
                editor.addTitle(payload, placement: placement)
            }
        }
        .sheet(isPresented: $showSFXSheet) {
            SFXSheet { effect in editor.addSFX(effect) }
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceRecorderSheet(projectID: editor.project.id,
                               startTime: editor.playback.currentTime) { fileName, duration, at in
                editor.addVoiceover(fileName: fileName, duration: duration, at: at)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet().environmentObject(editor)
        }
        .sheet(isPresented: $showInspector) {
            ClipInspectorView().environmentObject(editor)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $transitionAfterClipID) { clipID in
            TransitionPickerView(clipID: clipID).environmentObject(editor)
                .presentationDetents([.height(300)])
        }
        .sheet(item: $activeTool) { tool in
            Group {
                switch tool {
                case .speed: SpeedSheet()
                case .volume: VolumeSheet()
                case .filters: FilterSheet()
                case .effects: EffectsSheet()
                case .adjust: AdjustSheet()
                case .retouch: RetouchSheet()
                case .mask: MaskSheet()
                case .opacity: OpacitySheet()
                case .more: ClipInspectorView()
                }
            }
            .environmentObject(editor)
        }
        .photosPicker(isPresented: $showTimelinePicker,
                      selection: $pickedMedia,
                      maxSelectionCount: 20,
                      matching: .any(of: [.videos, .images]))
        .confirmationDialog("Add media", isPresented: $showMediaMenu, titleVisibility: .visible) {
            Button {
                showTimelinePicker = true
            } label: {
                Label("Camera Roll", systemImage: "photo.on.rectangle")
            }
            Button {
                showWebSearch = true
            } label: {
                Label("Web Search", systemImage: "globe")
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showWebSearch) {
            WebImageSearchSheet { image in
                await editor.importWebImage(from: image.fullURL)
            }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                PreviewPlayerView(player: editor.playback.player)
                    .ignoresSafeArea()
                    .onTapGesture { editor.togglePlayback() }
                Button {
                    showFullscreen = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding()
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { editor.errorMessage != nil },
            set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("OK") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Button {
                editor.playback.pause()
                appState.save(editor.project)
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.title3.weight(.semibold))
            }
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.title3)
            }
            .disabled(!editor.canUndo)
            .opacity(editor.canUndo ? 1 : 0.35)
            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward").font(.title3)
            }
            .disabled(!editor.canRedo)
            .opacity(editor.canRedo ? 1 : 0.35)

            Spacer()

            Text("\(TimeFormat.clock(editor.playback.currentTime)) \(Text("/ \(TimeFormat.clock(editor.project.duration))").foregroundStyle(.secondary))")
                .font(.subheadline.monospacedDigit().weight(.semibold))

            Spacer()

            Button {
                editor.playback.pause()
                appState.save(editor.project)
                dismiss()
            } label: {
                Image(systemName: "book").font(.title3)
            }
            Button {
                editor.playback.pause()
                showExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up").font(.title3)
            }
            .disabled(editor.project.primaryClips.isEmpty)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            if editor.playback.hasContent {
                PreviewPlayerView(player: editor.playback.player)
                    .onTapGesture { editor.togglePlayback() }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("Tap **Media** to add video")
                        .foregroundStyle(.secondary)
                }
            }
            if editor.isImporting || editor.isRebuilding || editor.isGeneratingCaptions || editor.isProcessing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(editor.isImporting ? "Importing…"
                         : editor.isGeneratingCaptions ? "Transcribing…"
                         : editor.isProcessing ? "Processing clip…" : "Updating preview…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            if let toast = editor.toast {
                VStack {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: editor.toast)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack {
            HStack(spacing: 18) {
                Button {
                    if editor.selectedClipID != nil {
                        showInspector = true
                    } else {
                        Haptics.warning()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                }
                Button {
                    editor.toggleOriginalAudio()
                } label: {
                    Image(systemName: editor.originalAudioEnabled
                          ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                }
                .disabled(editor.project.primaryClips.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                editor.togglePlayback()
            } label: {
                Image(systemName: editor.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }

            Button {
                showFullscreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
    }
}

extension UUID: Identifiable {
    public var id: UUID { self }
}
