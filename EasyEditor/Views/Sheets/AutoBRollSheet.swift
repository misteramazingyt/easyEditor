import SwiftUI

/// Auto B-Roll: pick what's covered, what media to pull, and how it's
/// inserted; Generate transcribes the storyline, finds mentions, and drops
/// matching media at each mention.
struct AutoBRollSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    @AppStorage(DesktopLibrarySettings.urlKey) private var serverURL = ""
    @AppStorage(DesktopLibrarySettings.tokenKey) private var serverToken = ""
    @AppStorage(PexelsService.apiKeyStorageKey) private var pexelsKey = ""

    @State private var settings = AutoBRollService.Settings()

    private var desktopService: DesktopLibraryService? {
        DesktopLibraryService(urlString: serverURL, token: serverToken)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    coverageSection
                    mediaSection
                    insertSection
                    sourceSection
                    matchingSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            generateButton
        }
        .foregroundStyle(.white)
        .presentationDetents([.large])
        .presentationBackground(Color(red: 0.05, green: 0.06, blue: 0.09))
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline) }
            Spacer()
            Text("AUTO B-ROLL").font(.subheadline.weight(.bold)).kerning(2)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "checkmark").font(.headline) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Coverage

    private var coverageSection: some View {
        VStack(spacing: 8) {
            label("Coverage")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 8) {
                coverageTile("People", "person", $settings.people)
                coverageTile("Places", "mappin.and.ellipse", $settings.places)
                coverageTile("Books", "book", $settings.books)
                coverageTile("Events", "building.columns", $settings.events)
                coverageTile("Periods", "flag", $settings.periods)
                coverageTile("Objects", "cube", $settings.objects)
            }
        }
    }

    private func coverageTile(_ name: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            Haptics.selection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(name.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6)
            }
            .foregroundStyle(isOn.wrappedValue ? .blue : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isOn.wrappedValue ? Color.blue.opacity(0.7) : .white.opacity(0.12),
                              lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }

    // MARK: Media / insert / source

    private var mediaSection: some View {
        VStack(spacing: 8) {
            label("Media to pull")
            Picker("Media", selection: $settings.media) {
                ForEach(AutoBRollService.MediaKind.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if settings.media != .images && pexelsKey.isEmpty {
                Text("Video needs a free Pexels API key (Settings) — will fall back to stills.")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var insertSection: some View {
        VStack(spacing: 8) {
            label("Insert style")
            Picker("Insert", selection: $settings.insertStyle) {
                ForEach(AutoBRollService.InsertStyle.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var sourceSection: some View {
        VStack(spacing: 8) {
            label("Source")
            Menu {
                ForEach(AutoBRollService.MediaSource.allCases, id: \.self) { source in
                    Button(source.rawValue) { settings.source = source }
                }
            } label: {
                HStack {
                    Text(settings.source.rawValue.uppercased())
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            .foregroundStyle(.white)
            if settings.source != .web && desktopService == nil {
                Text("Desktop Library isn't configured — web only.")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Matching

    private var matchingSection: some View {
        VStack(spacing: 12) {
            label("Matching")
            VStack(spacing: 10) {
                HStack {
                    Text("Confidence threshold").font(.subheadline)
                    Spacer()
                    Text("\(Int(settings.confidence * 100))%")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $settings.confidence, in: 0.4...0.95)
                Stepper("Max assets / mention: \(settings.maxAssetsPerMention)",
                        value: $settings.maxAssetsPerMention, in: 1...3)
                    .font(.subheadline)
                Stepper("Min duration: \(settings.minDurationFrames) frames",
                        value: $settings.minDurationFrames, in: 12...120, step: 6)
                    .font(.subheadline)
                Toggle("First mention only", isOn: $settings.firstMentionOnly)
                Toggle("Avoid repeats", isOn: $settings.avoidRepeats)
                    .disabled(settings.firstMentionOnly)
                Toggle("Fallback to stills", isOn: $settings.fallbackToStills)
            }
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Generate

    private var generateButton: some View {
        Button {
            editor.runAutoBRoll(settings, desktopService: desktopService, pexelsKey: pexelsKey)
        } label: {
            HStack(spacing: 10) {
                if editor.autoBRollStatus != nil {
                    ProgressView().tint(.white)
                    Text(editor.autoBRollStatus ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Image(systemName: "wand.and.stars")
                    Text("GENERATE B-ROLL")
                        .font(.subheadline.weight(.bold)).kerning(1.5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.blue.opacity(editor.autoBRollStatus == nil ? 0.85 : 0.4),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(editor.autoBRollStatus != nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).kerning(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
