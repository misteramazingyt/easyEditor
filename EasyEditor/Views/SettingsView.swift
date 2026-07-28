import SwiftUI

/// App settings: the desktop-library connection (Tailscale URL + token).
struct SettingsView: View {
    @AppStorage(DesktopLibrarySettings.urlKey) private var serverURL = ""
    @AppStorage(DesktopLibrarySettings.tokenKey) private var serverToken = ""
    @Environment(\.dismiss) private var dismiss

    enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
    }
    @State private var testState: TestState = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.y.z:8787", text: $serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Token (optional)", text: $serverToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            switch testState {
                            case .idle:
                                EmptyView()
                            case .testing:
                                ProgressView().controlSize(.small)
                            case .success(let message):
                                Label(message, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green).font(.caption)
                            case .failure(let message):
                                Label(message, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red).font(.caption)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .disabled(serverURL.isEmpty || testState == .testing)
                } header: {
                    Text("Desktop Library")
                } footer: {
                    Text("""
                    Run desktop-server/server.py on your desktop (see its README), \
                    with both devices on your tailnet. Use your desktop's Tailscale \
                    IP (tailscale ip -4) with http://, or a tailscale-serve \
                    https://…ts.net URL.
                    """)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.05, green: 0.06, blue: 0.09))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func testConnection() {
        guard let service = DesktopLibraryService(urlString: serverURL, token: serverToken) else {
            testState = .failure("Invalid URL")
            return
        }
        testState = .testing
        Task {
            do {
                let health = try await service.health()
                testState = .success(health.indexReady
                                     ? "\(health.indexedImages) images indexed"
                                     : "Connected (search index off)")
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
