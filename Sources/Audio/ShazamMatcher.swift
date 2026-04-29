import AVFAudio
import Combine
import Foundation
import ShazamKit

struct RecognizedSong: Identifiable, Hashable, Codable {
    let id: UUID
    let title: String
    let artist: String
    let isrc: String?
    let appleMusicID: String?
    let artworkURL: URL?
    let recognizedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        isrc: String? = nil,
        appleMusicID: String? = nil,
        artworkURL: URL? = nil,
        recognizedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.isrc = isrc
        self.appleMusicID = appleMusicID
        self.artworkURL = artworkURL
        self.recognizedAt = recognizedAt
    }

    init(item: SHMatchedMediaItem) {
        self.init(
            title: item.title ?? "Unknown title",
            artist: item.artist ?? "Unknown artist",
            isrc: item.isrc,
            appleMusicID: item.appleMusicID,
            artworkURL: item.artworkURL
        )
    }
}

@MainActor
final class ShazamMatcher: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case interrupted
        case error(String)
    }

    @Published private(set) var state: State = .idle
    let matchPublisher = PassthroughSubject<RecognizedSong, Never>()

    private let audioEngine = AVAudioEngine()
    private var session: SHSession?
    private var lastMatchedISRC: String?
    private var lastMatchedAt: Date?

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    /// Tracks whether the user explicitly asked to listen — used to auto-resume after an interruption ends.
    private var userIntentToListen = false

    override init() {
        super.init()
        installAudioObservers()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
    }

    func start() async {
        userIntentToListen = true
        guard state != .listening else { return }
        let granted = await AudioSessionManager.requestMicPermission()
        guard granted else {
            state = .error(AudioSessionManager.permissionDeniedMessage)
            userIntentToListen = false
            return
        }
        do {
            try AudioSessionManager.configureForListening()
            try startEngine()
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
            userIntentToListen = false
        }
    }

    func stop() {
        userIntentToListen = false
        teardownEngine()
        AudioSessionManager.deactivate()
        if state == .listening || state == .interrupted { state = .idle }
    }

    private func startEngine() throws {
        let newSession = SHSession()
        newSession.delegate = self
        self.session = newSession

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak newSession] buffer, audioTime in
            newSession?.matchStreamingBuffer(buffer, at: audioTime)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func teardownEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        session = nil
    }

    // MARK: - Interruptions & route changes

    private func installAudioObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            teardownEngine()
            if userIntentToListen { state = .interrupted }
        case .ended:
            guard userIntentToListen else { return }
            // Resume only if the system says we should (e.g., phone call ended cleanly).
            let shouldResume: Bool = {
                guard let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return false }
                return AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            }()
            guard shouldResume else { return }
            do {
                try AudioSessionManager.configureForListening()
                try startEngine()
                state = .listening
            } catch {
                state = .error(error.localizedDescription)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        // If the input device disappeared (e.g., headphones unplugged in a way that removed the active input),
        // the engine may stop accepting buffers. Restart conservatively only if we were listening and the engine died.
        guard state == .listening, !audioEngine.isRunning, userIntentToListen else { return }
        teardownEngine()
        do {
            try AudioSessionManager.configureForListening()
            try startEngine()
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

extension ShazamMatcher: SHSessionDelegate {
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        Task { @MainActor in
            self.handleMatch(item: item)
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // No match for this window — keep listening.
    }

    @MainActor
    private func handleMatch(item: SHMatchedMediaItem) {
        // Dedupe: ignore the same ISRC reported within 30s.
        let now = Date()
        if let isrc = item.isrc, isrc == lastMatchedISRC,
           let last = lastMatchedAt, now.timeIntervalSince(last) < 30 {
            return
        }
        lastMatchedISRC = item.isrc
        lastMatchedAt = now
        matchPublisher.send(RecognizedSong(item: item))
    }
}
