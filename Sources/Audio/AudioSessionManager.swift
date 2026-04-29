import AVFAudio
import Foundation

enum AudioSessionManager {
    static let permissionDeniedMessage = "Microphone access is off. Open Settings to enable it."

    static func configureForListening() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    static func requestMicPermission() async -> Bool {
        // iOS 17+ deployment target; AVAudioApplication is the modern API.
        await AVAudioApplication.requestRecordPermission()
    }

    static var currentMicPermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }
}
