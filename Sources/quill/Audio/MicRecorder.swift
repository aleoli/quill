import AVFoundation
import CoreAudio
import Foundation
import os

/// Records one input device to a file through a Core Audio IOProc, encoding
/// AAC mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// Deliberately not AVAudioEngine. That API drives input and output through a
/// single I/O unit, so capturing from a device other than the one backing the
/// default output fails to initialize the graph
/// (`-10868 kAudioUnitErr_FormatNotSupported`) — reproducible every time with
/// Bluetooth headphones as the default output, which is the normal way to take
/// a meeting. Its predecessor also bound to the system default before the
/// requested device could be selected, which killed the tap outright (rca-002).
/// A HAL IOProc takes the device as an argument: there is no default to fight,
/// no graph to initialize, and no route to renegotiate. It is the same
/// mechanism `SystemAudioRecorder` has used for the harder half of this job.
///
/// The tradeoff is `setVoiceProcessingEnabled` — Apple's echo canceller — which
/// only exists on the AVAudioEngine path. It was already off by default (on
/// headphones there is no echo to cancel) and measured broken on the routes
/// that mattered here (rca-001).
///
/// A watchdog polls the capture once a second for the whole session. A device
/// that stops delivering buffers, or delivers digital silence, is rebuilt in
/// place; if it stays broken the failure reaches the user while the meeting is
/// still running, instead of surfacing as an empty transcript hours later.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case noInputDevice
        case formatUnreadable(OSStatus)
        case formatUnsupported(AVAudioFormat)
        case fileCreationFailed(Error)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)

        var description: String {
            switch self {
            case .noInputDevice:
                return "no audio input device available"
            case .formatUnreadable(let s):
                return "couldn't read the mic's stream format (OSStatus \(s))"
            case .formatUnsupported(let f):
                return "can't downmix mic format \(f)"
            case .fileCreationFailed(let e):
                return "mic file creation failed: \(e)"
            case .ioProcCreationFailed(let s):
                return "mic IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s):
                return "mic device start failed (OSStatus \(s)) — it may be in use by another app"
            }
        }
    }

    /// Health of the mic track, pushed to the app so a bad track is visible
    /// while there's still a meeting to save.
    enum Health: Sendable, Equatable {
        /// Capture is running and delivering audio.
        case live
        /// The capture stopped and is being rebuilt.
        case rebuilding
        /// Buffers are arriving but every sample is a digital zero. Not a
        /// capture failure — a muted device, a closed privacy shutter, a webcam
        /// mic that only streams while its camera is on, or a denied microphone
        /// permission. Restarting would not fix it, so we only tell the user.
        case silent
        /// Recording, but not from the device that was asked for: it couldn't
        /// be opened, so capture fell back to the system default.
        case substituted(String)
        /// Capture is not recoverable for this session.
        case dead(String)

        /// Short label for the menu bar; nil while everything is fine.
        var alert: String? {
            switch self {
            case .live: return nil
            case .rebuilding: return "reconnecting mic"
            case .silent: return "mic has no signal"
            case .substituted(let name): return "recording \(name)"
            case .dead: return "mic not recording"
            }
        }
    }

    /// Called whenever the mic track's health changes. Invoked off the main
    /// actor (watchdog queue or the setup queue) — hop before touching UI.
    var onStatus: (@Sendable (Health) -> Void)?

    /// Peak level of the last second, 0…1, with decay. Read by the menu-bar
    /// ticker to draw a level meter.
    var level: Float { state.withLock { $0.levelPeak } }

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    var firstBufferAt: Date? { state.withLock { $0.firstBufferAt } }

    private(set) var isRecording = false

    // MARK: - Watchdog thresholds

    /// No buffer for this long means capture is dead, not merely quiet — a live
    /// IOProc fires every few milliseconds.
    private static let stallSeconds: TimeInterval = 3
    /// Consecutive one-second ticks of digital zero before we tell the user.
    /// Generous on purpose: a real mic in a silent room still has a noise
    /// floor, but some devices take seconds to start streaming (the OBSBOT
    /// Meet 4K stays at digital zero until its camera is on), and crying wolf
    /// on a track that is about to come alive is worse than a late warning.
    private static let silentTicksBeforeWarning = 10
    private static let maxRecoveryAttempts = 3

    // MARK: - Capture state

    private var file: AVAudioFile?
    private var url: URL?
    /// The mono format the file was opened with. Fixed for the whole session:
    /// if a rebuild lands on a device with a different sample rate, the
    /// converter absorbs it instead of corrupting the file.
    private var fileFormat: AVAudioFormat?
    /// What the caller asked for. nil means "follow the system default", which
    /// is re-resolved on every rebuild.
    private var requestedDeviceID: AudioDeviceID?
    /// The device capture is actually running on.
    private var activeDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private let captureQueue = DispatchQueue(label: "com.digimata.quill.mic-capture")
    private let setupQueue = DispatchQueue(label: "com.digimata.quill.mic-setup")
    private let watchdogQueue = DispatchQueue(label: "com.digimata.quill.mic-watchdog")
    private var watchdog: DispatchSourceTimer?

    /// Real-time state: written from the IOProc, read by the watchdog and the
    /// main actor.
    private struct CaptureState {
        var firstBufferAt: Date?
        var lastBufferAt: Date?
        /// When the current IOProc started, so a capture that never delivers a
        /// single buffer still counts as stalled.
        var startedAt = Date()
        /// Peak since the last watchdog tick; reset every tick.
        var peakSinceTick: Float = 0
        /// Decaying peak for the menu-bar level meter.
        var levelPeak: Float = 0
        /// Consecutive watchdog ticks that saw digital silence.
        var silentTicks = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: CaptureState())

    private struct RecoveryState {
        var inProgress = false
        var attempts = 0
        var givenUp = false
    }
    private let recovery = OSAllocatedUnfairLock(initialState: RecoveryState())

    /// Last health pushed to `onStatus`, so transitions can be detected and the
    /// user is told once rather than every second.
    private let lastHealth = OSAllocatedUnfairLock(initialState: Health.live)

    /// Per-IOProc converter cache. The IOProc is serialized on its own queue,
    /// so a plain box needs no lock; it is captured by the block and dies with it.
    private final class Downmixer {
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var warnedAboutLayout = false
    }

    deinit { watchdog?.cancel() }

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    /// `deviceID` selects a specific input device; nil follows the system
    /// default. The id must be valid for the current process lifetime —
    /// callers resolve a persisted UID via `AudioDevices.deviceID(forUID:)`.
    ///
    /// Async because opening a device can block for a moment (longer if the
    /// device is wedged), and the caller is the main actor.
    func start(writingTo url: URL, deviceID: AudioDeviceID? = nil) async throws {
        guard !isRecording else { return }
        self.url = url
        self.requestedDeviceID = deviceID

        // AVAudioEngine used to trigger the microphone TCC prompt as a side
        // effect of starting. A HAL IOProc does not: without permission it just
        // hands back digital zeros forever. Ask explicitly, so the first run
        // prompts instead of silently recording nothing.
        await Self.ensureMicrophoneAccess(warn: warn)

        if Config.micVoiceProcessing() {
            warn("mic_voice_processing is set, but echo cancellation is not available "
                + "on the Core Audio capture path — recording raw mic (see .issues/rca-002)")
        }

        do {
            try await offMain { try self.attach(deviceID: deviceID) }
        } catch {
            // The chosen device may be busy, unplugged since it was picked, or
            // refusing to open. Recording the default mic beats not recording.
            guard deviceID != nil else { throw error }
            let wanted = deviceID.flatMap(AudioDevices.deviceName(forID:)) ?? "the selected device"
            warn("can't capture from \(wanted) (\(error)) — falling back to the system default input")
            try await offMain { try self.attach(deviceID: nil) }
            requestedDeviceID = nil
            let actual = AudioDevices.defaultInputDeviceID()
                .flatMap(AudioDevices.deviceName(forID:)) ?? "system default"
            report(.substituted(actual))
        }
        isRecording = true
        startWatchdog()
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        watchdog?.cancel()
        watchdog = nil
        teardownCapture()
        // Releasing the last reference is what writes CAF's packet table.
        file = nil
    }

    /// Make sure the process may actually read a microphone. Returns once the
    /// answer is known; capture proceeds regardless, because a denied mic
    /// yields a silent track that the watchdog reports rather than a failure
    /// that loses the system-audio side of the meeting too.
    private static func ensureMicrophoneAccess(warn: (String) -> Void) async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            warn("microphone access was denied — the mic track will be silent")
        case .denied, .restricted:
            warn("microphone access is denied — grant it in System Settings → "
                + "Privacy & Security → Microphone, or the mic track will be silent")
        default:
            break
        }
    }

    // MARK: - Capture

    /// Open a device and start its IOProc, opening the output file on the first
    /// call. Called at start and again by the watchdog when capture dies.
    /// Runs off the main actor.
    private func attach(deviceID: AudioDeviceID?) throws {
        guard let device = deviceID ?? AudioDevices.defaultInputDeviceID() else {
            throw RecorderError.noInputDevice
        }
        let deviceFormat = try Self.inputFormat(of: device)

        // One explicit mono format. Speech models want a single channel, and
        // fixing it here means the file's shape never depends on which device
        // a rebuild happens to land on.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: deviceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(deviceFormat)
        }

        // The file is opened once and outlives every rebuild, so recovered
        // capture keeps appending to the same track instead of truncating it.
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: monoFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
            do {
                file = try AVAudioFile(
                    forWriting: url!,
                    settings: settings,
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
            fileFormat = monoFormat
        }
        guard let target = fileFormat else { throw RecorderError.formatUnsupported(monoFormat) }

        let mixer = Downmixer()
        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, device, captureQueue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file else { return }
            guard let captured = AVAudioPCMBuffer(
                pcmFormat: deviceFormat,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else {
                // The device presents more than one input stream, so its buffer
                // list doesn't match the format we read from stream 0.
                if !mixer.warnedAboutLayout {
                    mixer.warnedAboutLayout = true
                    self.warn("mic buffer layout doesn't match \(deviceFormat) — dropping buffers")
                }
                return
            }
            guard let mono = Self.downmix(captured, to: target, using: mixer) else { return }

            let peak = Self.peak(of: mono)
            let now = Date()
            self.state.withLock { state in
                if state.firstBufferAt == nil { state.firstBufferAt = now }
                state.lastBufferAt = now
                state.peakSinceTick = max(state.peakSinceTick, peak)
                state.levelPeak = max(state.levelPeak, peak)
            }

            do {
                try file.write(from: mono)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
        guard status == noErr, let newProcID else {
            throw RecorderError.ioProcCreationFailed(status)
        }

        status = AudioDeviceStart(device, newProcID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, newProcID)
            throw RecorderError.deviceStartFailed(status)
        }

        activeDeviceID = device
        procID = newProcID

        let now = Date()
        state.withLock { state in
            state.startedAt = now
            state.lastBufferAt = nil
            state.silentTicks = 0
            state.peakSinceTick = 0
        }

        let name = AudioDevices.deviceName(forID: device) ?? "id \(device)"
        let following = deviceID == nil ? " (system default)" : ""
        FileHandle.standardError.write(Data(
            "mic: device=\(name)\(following) input=\(deviceFormat) file=\(target)\n".utf8
        ))
    }

    /// Stop and release the IOProc. Safe to call when nothing is running.
    /// `AudioDeviceStop` guarantees the block won't be called again once it
    /// returns, which is what makes releasing the file afterwards safe.
    private func teardownCapture() {
        guard let procID, activeDeviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        AudioDeviceStop(activeDeviceID, procID)
        AudioDeviceDestroyIOProcID(activeDeviceID, procID)
        self.procID = nil
    }

    /// The virtual format of a device's first input stream — the shape the
    /// IOProc will hand us. Devices with several input streams exist; we read
    /// stream 0 and let the IOProc detect a layout it can't wrap.
    private static func inputFormat(of device: AudioDeviceID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            throw RecorderError.formatUnreadable(status)
        }
        var streams = [AudioStreamID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size
        )
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams)
        guard status == noErr, let stream = streams.first else {
            throw RecorderError.formatUnreadable(status)
        }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.formatUnreadable(status)
        }
        return format
    }

    /// Absolute peak of a mono float buffer. Cheap enough to run on the capture
    /// thread, and it's what the watchdog and the level meter both read.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        return peak
    }

    /// Convert a captured buffer to the file's mono format, rebuilding the
    /// converter whenever the incoming format changes (device swapped, sample
    /// rate renegotiated). Returns the buffer untouched when it already matches.
    private static func downmix(
        _ buffer: AVAudioPCMBuffer,
        to target: AVAudioFormat,
        using mixer: Downmixer
    ) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if source.sampleRate == target.sampleRate,
           source.channelCount == target.channelCount,
           source.commonFormat == target.commonFormat,
           source.isInterleaved == target.isInterleaved {
            return buffer
        }
        if mixer.inputFormat != source {
            mixer.converter = AVAudioConverter(from: source, to: target)
            mixer.inputFormat = source
        }
        guard let converter = mixer.converter else { return nil }

        // Sample-rate conversion needs the pull-based API — `convert(to:from:)`
        // only handles matched rates, and a rebuild can land on a device
        // running at a different rate than the file.
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        // The input block is @Sendable, so the one-shot flag can't be a
        // captured var. It's only ever touched on the capture thread.
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            let first = supplied.withLock { flag in
                if flag { return false }
                flag = true
                return true
            }
            guard first else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else {
            if let error {
                FileHandle.standardError.write(Data("mic downmix failed: \(error)\n".utf8))
            }
            return nil
        }
        return out
    }

    /// Run blocking Core Audio setup off the caller's actor, with a timeout so
    /// a wedged device can't hang the app forever.
    private func offMain(timeout: TimeInterval = 10, _ body: @escaping @Sendable () throws -> Void) async throws {
        // OSAllocatedUnfairLock is Sendable and can be safely captured by
        // @Sendable closures — unlike a captured var, which Swift 6 rejects.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resume: @Sendable (Error?) -> Void = { error in
                let wasFirst = resumed.withLock { flag in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard wasFirst else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            setupQueue.async {
                do {
                    try body()
                    resume(nil)
                } catch {
                    resume(error)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resume(RecorderError.deviceStartFailed(OSStatus(-1)))
            }
        }
    }

    // MARK: - Watchdog

    /// Poll capture once a second for the whole session. This is the only thing
    /// standing between a device that quietly stops delivering audio and a
    /// meeting recorded with an empty mic track.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard isRecording else { return }
        let now = Date()
        let (stalledFor, silentTicks) = state.withLock { state -> (TimeInterval, Int) in
            let peak = state.peakSinceTick
            state.silentTicks = peak == 0 ? state.silentTicks + 1 : 0
            // Decay so the meter falls back instead of sticking at the loudest
            // moment of the meeting.
            state.levelPeak = max(peak, state.levelPeak * 0.5)
            state.peakSinceTick = 0
            let reference = state.lastBufferAt ?? state.startedAt
            return (now.timeIntervalSince(reference), state.silentTicks)
        }

        // Capture that is delivering real audio again earns back its recovery
        // budget: a long meeting shouldn't run out of retries because of
        // unrelated hiccups an hour apart.
        if stalledFor < 1, silentTicks == 0 {
            recovery.withLock { state in
                state.attempts = 0
                state.givenUp = false
            }
        }

        if stalledFor > Self.stallSeconds {
            // No buffers at all: the device stopped feeding us. Reopening it is
            // the cure — and if it's gone, we fall back to the default.
            Task { await self.recover(reason: "no audio from the mic for \(Int(stalledFor))s") }
        } else if silentTicks == Self.silentTicksBeforeWarning {
            // Buffers are flowing but they're all zeros. Capture is healthy and
            // the device simply isn't sending anything — reopening it would
            // only lose audio, so say so and let the meter tell the rest.
            warn("the mic has been digitally silent for \(silentTicks)s — "
                + "check that the device isn't muted")
            report(.silent)
        } else if silentTicks == 0, case .silent = lastReported {
            report(.live)
        }
    }

    /// Reopen the device, still writing to the same file. Serialized and
    /// capped: a device that can't be revived must not spin. If it can't be
    /// reopened at all, fall back to the system default — recording the wrong
    /// mic beats recording nothing.
    private func recover(reason: String) async {
        guard isRecording else { return }
        let attempt: Int? = recovery.withLock { state in
            if state.inProgress || state.givenUp { return nil }
            if state.attempts >= Self.maxRecoveryAttempts {
                state.givenUp = true
                return nil
            }
            state.inProgress = true
            state.attempts += 1
            return state.attempts
        }
        guard let attempt else {
            if recovery.withLock({ $0.givenUp }) {
                let message = "mic track is dead (\(reason)) — this session has no mic audio"
                warn(message)
                report(.dead(message))
            }
            return
        }

        warn("mic capture stalled (\(reason)) — reopening the device "
            + "(attempt \(attempt)/\(Self.maxRecoveryAttempts))")
        report(.rebuilding)

        teardownCapture()
        do {
            try await offMain { try self.attach(deviceID: self.requestedDeviceID) }
            report(.live)
        } catch {
            warn("mic reopen failed: \(error)")
            // The chosen device may be gone for good (unplugged mid-meeting).
            if requestedDeviceID != nil {
                do {
                    try await offMain { try self.attach(deviceID: nil) }
                    requestedDeviceID = nil
                    let actual = AudioDevices.defaultInputDeviceID()
                        .flatMap(AudioDevices.deviceName(forID:)) ?? "system default"
                    warn("falling back to the system default input (\(actual))")
                    report(.substituted(actual))
                    recovery.withLock { $0.inProgress = false }
                    return
                } catch {
                    warn("system default input also failed: \(error)")
                }
            }
            if attempt >= Self.maxRecoveryAttempts {
                recovery.withLock { $0.givenUp = true }
                let message = "mic track is dead (\(reason)) — this session has no mic audio"
                report(.dead(message))
            }
        }
        recovery.withLock { $0.inProgress = false }
    }

    // MARK: -

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    private var lastReported: Health { lastHealth.withLock { $0 } }

    private func report(_ health: Health) {
        let changed = lastHealth.withLock { current -> Bool in
            guard current != health else { return false }
            current = health
            return true
        }
        guard changed else { return }
        onStatus?(health)
    }
}
