import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var matcher: ShazamMatcher
    @EnvironmentObject var pipeline: MatchPipeline
    @EnvironmentObject var settings: AppSettings
    @State private var showingSettings = false
    @State private var signInError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusBanner
                Spacer()
                listenButton
                Spacer()
                recentList
            }
            .padding()
            .navigationTitle("Shazam → Spotify")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(auth)
                    .environmentObject(settings)
                    .environmentObject(pipeline)
            }
            .alert("Sign-in failed", isPresented: .constant(signInError != nil), presenting: signInError) { _ in
                Button("OK") { signInError = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !auth.isSignedIn {
            VStack(spacing: 12) {
                Text("Connect Spotify to start auto-adding songs.")
                    .multilineTextAlignment(.center)
                Button("Sign in to Spotify") {
                    Task {
                        do {
                            try await auth.signIn()
                        } catch SpotifyAuth.AuthError.userCancelled {
                            // User dismissed the sheet — silently ignore.
                        } catch {
                            signInError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else {
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(connectedText)
                Spacer()
                if let name = displayedPlaylistName {
                    Text("→ \(name)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var connectedText: String {
        if let name = settings.userDisplayName { return "Connected as \(name)" }
        return "Spotify connected"
    }

    private var displayedPlaylistName: String? {
        settings.targetPlaylistName ?? (settings.targetPlaylistID == nil ? Config.defaultPlaylistName : nil)
    }

    private var listenButton: some View {
        Button {
            Task {
                switch matcher.state {
                case .listening, .interrupted:
                    matcher.stop()
                case .idle, .error:
                    await matcher.start()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(buttonGradient)
                    .frame(width: 200, height: 200)
                    .shadow(radius: matcher.state == .listening ? 16 : 6)
                Image(systemName: buttonIcon)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: matcher.state == .listening)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(buttonAccessibilityLabel)
        .accessibilityValue(buttonAccessibilityValue)
        .accessibilityHint(buttonAccessibilityHint)
        .overlay(alignment: .bottom) {
            statusLabel
                .offset(y: 36)
        }
    }

    private var buttonAccessibilityLabel: String {
        switch matcher.state {
        case .idle: return "Listen for music"
        case .listening: return "Listening"
        case .interrupted: return "Listening paused"
        case .error: return "Microphone unavailable"
        }
    }

    private var buttonAccessibilityValue: String {
        currentStatusText
    }

    private var buttonAccessibilityHint: String {
        switch matcher.state {
        case .listening, .interrupted: return "Double-tap to stop"
        case .idle: return "Double-tap to start identifying songs"
        case .error: return "Open Settings to grant microphone access"
        }
    }

    private var buttonIcon: String {
        switch matcher.state {
        case .listening: return "waveform"
        case .interrupted: return "pause.fill"
        case .error: return "mic.slash.fill"
        case .idle: return "mic.fill"
        }
    }

    private var buttonGradient: LinearGradient {
        switch matcher.state {
        case .listening:
            return LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
        case .interrupted:
            return LinearGradient(colors: [.gray, .secondary], startPoint: .top, endPoint: .bottom)
        case .error:
            return LinearGradient(colors: [.red, .orange], startPoint: .top, endPoint: .bottom)
        case .idle:
            return LinearGradient(colors: [.green, .teal], startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch matcher.state {
        case .idle:
            Text("Tap to listen")
                .font(.headline)
                .foregroundStyle(.secondary)
        case .listening:
            Text(currentStatusText)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .animation(.default, value: pipeline.lastStatus)
        case .interrupted:
            Text("Paused — audio interrupted")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .error(let msg):
            VStack(spacing: 6) {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if msg == AudioSessionManager.permissionDeniedMessage,
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { UIApplication.shared.open(url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var currentStatusText: String {
        switch pipeline.lastStatus {
        case .idle: return "Listening…"
        case .searching(let title): return "Found “\(title)” — checking Spotify…"
        case .added(let title, _): return "Added “\(title)” to playlist"
        case .skipped(let reason, let title): return "“\(title)”: \(reason)"
        case .failed(let reason, _): return "Error: \(reason)"
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent catches").font(.headline)
                Spacer()
                if !pipeline.caughtSongs.isEmpty {
                    Text("\(pipeline.caughtSongs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(pipeline.caughtSongs.count) songs caught")
                }
            }
            if pipeline.caughtSongs.isEmpty {
                onboardingChecklist
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(pipeline.caughtSongs) { entry in
                            CaughtRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var onboardingChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChecklistRow(
                done: auth.isSignedIn,
                title: "Sign in to Spotify",
                detail: auth.isSignedIn ? "Connected" : "Tap the green button above"
            )
            ChecklistRow(
                done: settings.targetPlaylistID != nil,
                title: "Pick a target playlist",
                detail: settings.targetPlaylistID != nil
                    ? (settings.targetPlaylistName ?? "Selected")
                    : "Defaults to “\(Config.defaultPlaylistName)” (auto-created on first match)"
            )
            ChecklistRow(
                done: false,
                title: "Tap the mic while music plays",
                detail: "ShazamKit identifies the song; matches land in your playlist"
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct ChecklistRow: View {
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CaughtRow: View {
    let entry: CaughtEntry
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = entry.spotifyURL { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle).font(.body).bold().lineLimit(1)
                    Text(entry.displayArtist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        statusText
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(entry.timestamp, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                statusIcon
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(entry.spotifyURL == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(entry.spotifyURL != nil ? "Double-tap to open in Spotify" : "")
    }

    private var accessibilityDescription: String {
        let statusPhrase: String
        switch entry.status {
        case .added: statusPhrase = "added to playlist"
        case .alreadyInPlaylist: statusPhrase = "already in playlist"
        case .notOnSpotify: statusPhrase = "not found on Spotify"
        case .failed: statusPhrase = "failed to add"
        }
        return "\(entry.displayTitle) by \(entry.displayArtist). \(statusPhrase)."
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = entry.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty: artworkPlaceholder
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure: artworkPlaceholder
                @unknown default: artworkPlaceholder
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            artworkPlaceholder
                .frame(width: 48, height: 48)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .added:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .alreadyInPlaylist:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .notOnSpotify:
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch entry.status {
        case .added: Text("Added").font(.caption2).foregroundStyle(.green)
        case .alreadyInPlaylist: Text("Already in playlist").font(.caption2).foregroundStyle(.secondary)
        case .notOnSpotify: Text("Not on Spotify").font(.caption2).foregroundStyle(.orange)
        case .failed: Text("Failed").font(.caption2).foregroundStyle(.red)
        }
    }
}
