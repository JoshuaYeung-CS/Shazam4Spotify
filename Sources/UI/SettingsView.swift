import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pipeline: MatchPipeline
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var showingPlaylistPicker = false
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if auth.isSignedIn {
                        Button("Sign out of Spotify", role: .destructive) {
                            Task { await auth.signOut() }
                        }
                    } else {
                        Button("Sign in to Spotify") {
                            Task { try? await auth.signIn() }
                        }
                    }
                }

                Section("Target playlist") {
                    Button {
                        showingPlaylistPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(settings.targetPlaylistName ?? "Default — \(Config.defaultPlaylistName)")
                                    .foregroundStyle(.primary)
                                Text(settings.targetPlaylistID == nil
                                     ? "Auto-creates if missing"
                                     : "Tap to change")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!auth.isSignedIn)

                    if let id = settings.targetPlaylistID,
                       let url = URL(string: "spotify:playlist:\(id)") {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open playlist in Spotify", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                Section("Feedback") {
                    Toggle("Haptics on match", isOn: $settings.hapticsEnabled)
                }

                Section("History") {
                    HStack {
                        Text("Caught songs")
                        Spacer()
                        Text("\(pipeline.caughtSongs.count)").foregroundStyle(.secondary)
                    }
                    Button("Clear history", role: .destructive) {
                        confirmingClear = true
                    }
                    .disabled(pipeline.caughtSongs.isEmpty)
                }

                Section("About") {
                    HStack {
                        Text("Client ID")
                        Spacer()
                        Text(Config.spotifyClientID.prefix(8) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPlaylistPicker) {
                PlaylistPickerView()
                    .environmentObject(auth)
                    .environmentObject(settings)
                    .environmentObject(pipeline)
            }
            .confirmationDialog(
                "Clear history?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { pipeline.clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only clears the on-device list. Songs already added to your Spotify playlist stay there.")
            }
        }
    }
}
