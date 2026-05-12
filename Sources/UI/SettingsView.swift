import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pipeline: MatchPipeline
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var showingPlaylistPicker = false
    @State private var confirmingClear = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if auth.isSignedIn {
                        if let name = settings.userDisplayName {
                            HStack {
                                Text("Signed in as")
                                Spacer()
                                Text(name).foregroundStyle(.secondary)
                            }
                        }
                        Button("Sign out of Spotify", role: .destructive) {
                            Task { await auth.signOut() }
                        }
                    } else {
                        Button("Sign in to Spotify") {
                            Task { try? await auth.signIn() }
                        }
                    }
                }

                Section {
                    Toggle(isOn: $settings.saveToLikedSongs) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Liked Songs")
                            Text("Add every match to your library").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $settings.saveToShazamPlaylist) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Config.defaultPlaylistName)
                            Text("Auto-created playlist of every match").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if settings.saveToShazamPlaylist,
                       let id = settings.targetPlaylistID,
                       let url = URL(string: "spotify:playlist:\(id)") {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open \(Config.defaultPlaylistName) in Spotify", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Default destinations")
                } footer: {
                    Text("Every recognized song is added to each enabled destination.")
                }

                Section {
                    if settings.additionalPlaylistIDs.isEmpty {
                        Text("No additional playlists picked")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.additionalPlaylistIDs, id: \.self) { id in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(settings.additionalPlaylistNames[id] ?? "Playlist")
                                    Text(id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    removePlaylist(id: id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button {
                        showingPlaylistPicker = true
                    } label: {
                        Label("Add a playlist", systemImage: "plus.circle.fill")
                    }
                    .disabled(!auth.isSignedIn)
                } header: {
                    Text("Additional playlists")
                } footer: {
                    Text("Matches are mirrored into each. Useful for genre playlists, shared collabs, etc.")
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
                        Text("Version")
                        Spacer()
                        Text(versionString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
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
                Text("This only clears the on-device list. Songs already added to your Spotify playlists stay there.")
            }
        }
    }

    private func removePlaylist(id: String) {
        settings.additionalPlaylistIDs.removeAll { $0 == id }
        settings.additionalPlaylistNames.removeValue(forKey: id)
    }
}
