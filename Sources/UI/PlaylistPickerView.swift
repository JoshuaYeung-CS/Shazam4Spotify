import SwiftUI

struct PlaylistPickerView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pipeline: MatchPipeline
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [SpotifyPlaylist] = []
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add a playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !auth.isSignedIn {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("Sign in to Spotify first").font(.headline)
                Text("Then you can pick playlists to mirror matches into.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if loading {
            ProgressView("Loading your playlists…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(err).multilineTextAlignment(.center).padding(.horizontal)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    if playlists.isEmpty {
                        Text("No playlists found in your library.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(playlists) { playlist in
                            row(for: playlist)
                        }
                    }
                } header: {
                    HStack {
                        Text("Your playlists")
                        Spacer()
                        if !playlists.isEmpty {
                            Text("\(playlists.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Tap a playlist to mirror matches into it. Tap again to remove.")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private func row(for playlist: SpotifyPlaylist) -> some View {
        let isAdded = settings.additionalPlaylistIDs.contains(playlist.id)
        let isShazamTarget = settings.targetPlaylistID == playlist.id

        Button {
            toggle(playlist: playlist)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).bold()
                    if isShazamTarget {
                        Text("Already used as your \(Config.defaultPlaylistName) playlist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let count = playlist.tracks?.total {
                        Text("\(count) track\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isAdded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if isShazamTarget {
                    Image(systemName: "star.circle.fill").foregroundStyle(.yellow)
                } else {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isShazamTarget)
        .accessibilityLabel("\(playlist.name)\(isAdded ? ", added" : "")")
    }

    private func toggle(playlist: SpotifyPlaylist) {
        if settings.additionalPlaylistIDs.contains(playlist.id) {
            settings.additionalPlaylistIDs.removeAll { $0 == playlist.id }
            settings.additionalPlaylistNames.removeValue(forKey: playlist.id)
        } else {
            settings.additionalPlaylistIDs.append(playlist.id)
            var names = settings.additionalPlaylistNames
            names[playlist.id] = playlist.name
            settings.additionalPlaylistNames = names
        }
    }

    private func load() async {
        guard auth.isSignedIn else { return }
        loading = true
        loadError = nil
        do {
            let client = SpotifyClient(auth: auth)
            playlists = try await client.allPlaylists(maxItems: 500)
            loading = false
        } catch {
            loadError = error.localizedDescription
            loading = false
        }
    }
}
