import AVFoundation
import Foundation
import os

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    /// Selected input device for this session, retained so the raw fallback
    /// path reattaches to the same device instead of the system default.
    private var deviceID: AudioDeviceID?
    /// The system default input device before we swapped it to `deviceID`.
    /// Restored in `stop()`. nil when no swap was performed (device is the
    /// default, or no device was selected).
    private var savedDefaultDeviceID: AudioDeviceID?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    /// `deviceID` selects a specific input device; nil follows the system
    /// default. The id must be valid for the current process lifetime —
    /// callers resolve a persisted UID via `AudioDevices.deviceID(forUID:)`.
    ///
    /// Async because `AVAudioEngine.start()` can block for several seconds
    /// (or indefinitely) when binding to a non-default input device whose
    /// format hasn't settled — running it on the main thread would freeze
    /// the entire UI. The engine start runs on a background queue with a
    /// timeout; the caller's actor is free to handle events while waiting.
    func start(writingTo url: URL, deviceID: AudioDeviceID? = nil) async throws {
        guard !isRecording else { return }
        self.url = url
        self.deviceID = deviceID
        try await attach(voiceProcessing: Config.micVoiceProcessing(), deviceID: deviceID)
        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent. Restores the
    /// system default input device if it was swapped in `start`.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        AudioDevices.restoreDefaultInputDevice(savedDefaultDeviceID)
        savedDefaultDeviceID = nil
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips. Async because `engine.start()` is offloaded to
    /// a background queue (see `start`).
    private func attach(voiceProcessing: Bool, deviceID: AudioDeviceID? = nil) async throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        // AVAudioEngine.inputNode always binds to the system default input
        // device. setDeviceID on the underlying AU is unreliable — it can
        // hang engine.start() or produce digital silence even when the
        // format looks correct. The only reliable way to record from a
        // specific device is to temporarily set it as the system default,
        // start the engine, and restore the original default on stop.
        // Skip the swap when the selected device IS already the default.
        if let deviceID, deviceID != AudioDevices.defaultInputDeviceID() {
            savedDefaultDeviceID = AudioDevices.setDefaultInputDevice(deviceID)
        }

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        let resolvedFormat = inputFormat

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: resolvedFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(resolvedFormat)
        }

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

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: resolvedFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try await startEngineAsync(input: input)
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }

        let deviceName = deviceID.flatMap(AudioDevices.deviceName(forID:)) ?? "system default"
        let report = "mic: device=\(deviceName) "
            + "voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Run `engine.start()` on a background queue with a timeout.
    /// `AVAudioEngine.start()` can block for seconds (or indefinitely) when
    /// the input device's format hasn't settled after `setDeviceID` — calling
    /// it synchronously on the main thread freezes the entire UI. The
    /// continuation resumes on success, on error, or on timeout — whichever
    /// comes first. A late-arriving success after timeout is a no-op (the
    /// engine will be cleaned up when the recorder is deallocated).
    private func startEngineAsync(input: AVAudioInputNode, timeout: TimeInterval = 10) async throws {
        // OSAllocatedUnfairLock is Sendable and can be safely captured by
        // @Sendable closures — unlike a captured var, which Swift 6 rejects.
        let resumed = OSAllocatedUnfairLock(initialState: false)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The resume closure is captured by two @Sendable dispatch closures
            // (the engine start and the timeout); the lock makes the one-shot
            // resume safe across threads.
            let resume: @Sendable (Error?) -> Void = { error in
                let wasFirst = resumed.withLock { flag in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard wasFirst else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.engine.start()
                    resume(nil)
                } catch {
                    resume(error)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resume(RecorderError.engineStartFailed(
                    NSError(domain: "quill", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "engine start timed out after \(Int(timeout))s — the selected device may be in use or its format is incompatible",
                    ])
                ))
            }
        }
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        Task { await self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else { return }
            do {
                try converter.convert(to: mono, from: buffer)
                try file.write(from: mono)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() async {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        firstBufferAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            // Pass nil for deviceID: the system default was already swapped
            // in the first attach() call, and the engine's inputNode is
            // already bound to the right device. Re-swapping would lose the
            // savedDefaultDeviceID.
            try await attach(voiceProcessing: false, deviceID: nil)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }
}
