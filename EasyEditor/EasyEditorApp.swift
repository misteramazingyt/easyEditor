import SwiftUI
import AVFAudio

@main
struct EasyEditorApp: App {
    @StateObject private var state = AppState()

    init() {
        // Without an explicit category iOS uses .soloAmbient, which the
        // ring/silent switch mutes — making all playback appear broken.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.25, green: 0.62, blue: 0.96))
                .onOpenURL { url in
                    state.handleIncomingFile(url)
                }
        }
    }
}
