import SwiftUI

@main
struct EasyEditorApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.25, green: 0.62, blue: 0.96))
        }
    }
}
