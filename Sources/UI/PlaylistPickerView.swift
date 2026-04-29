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
                .navigationTitle("Choose playlist")
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
        if loading {
            ProgressView("Loading your playlists…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(err).multilineTextAlignment(.center).padding(.horizontal)
                Button("Retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    Button {
                        settings.targetPlaylistID = nil
                        settings.targetPlaylistName = nil
                        pipeline.invalidatePlaylistCache()
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Default — auto-create").bold()
                                Text("Will use “\(Config.defaultPlaylistName)” (creates it if missing)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.targetPlaylistID == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section("Your playlists") {
                    ForEach(playlists) { playlist in
                        Button {
                            settings.targetPlaylistID = playlist.id
                            settings.targetPlaylistName = playlist.name
                            pipeline.invalidatePlaylistCache()
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).bold()
                                    if let count = playlist.tracks?.total {
                                        Text("\(count) track\(count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if settings.targetPlaylistID == playlist.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            let client = SpotifyClient(auth: auth)
            playlists = try await client.playlists(limit: 50)
            loading = false
        } catch {
            loadError = error.localizedDescription
            loading = false
        }
    }
}
