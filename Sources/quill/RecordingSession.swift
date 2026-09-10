import CoreAudio
import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
///
/// `@unchecked Sendable`: the session is created on the main actor and its
/// `start()` runs partially on a background queue (the mic engine start).
/// Access is serialized — `start()` completes before `stop()` can be called
/// (the `starting` flag in `AppController` prevents concurrent starts).
final class RecordingSession: @unchecked Sendable {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    /// Selected mic device id (current process lifetime). nil = system default.
    private let micDeviceID: AudioDeviceID?

    /// Peak mic level over the last second, 0…1. Drives the menu-bar meter so
    /// a mic that stopped delivering audio is visible during the meeting.
    var micLevel: Float { mic.level }

    /// Observe the mic track's health (stalls, silence, unrecoverable failure).
    /// Set before `start()`. The handler is invoked off the main actor.
    func setMicStatusHandler(_ handler: @escaping @Sendable (MicRecorder.Health) -> Void) {
        mic.onStatus = handler
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet. `micDeviceID` selects the
    /// input device for the mic track; nil follows the system default.
    init(root: URL, micDeviceID: AudioDeviceID? = nil) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        self.micDeviceID = micDeviceID
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently. Async because
    /// the mic's `AVAudioEngine.start()` runs on a background queue (it can
    /// block when binding to a non-default device).
    func start() async throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try await mic.start(
                writingTo: dir.appendingPathComponent("mic.caf"),
                deviceID: micDeviceID
            )
        } catch {
            system.stop()
            throw error
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
