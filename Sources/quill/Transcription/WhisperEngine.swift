import AVFoundation
import Foundation
import WhisperKit

/// Whisper (large-v3-turbo by default) via WhisperKit's Core ML port, running
/// on the Apple Neural Engine. Models download once into WhisperKit's
/// HuggingFace cache (~626 MB for turbo); after that, transcription runs
/// entirely on-device. Multilingual — set `transcription.language` in config
/// to force a language, or leave it unset for auto-detection.
///
/// Slower than Parakeet (English-only) but covers every language Whisper
/// supports, so it's the fallback / multilingual option behind the same
/// `TranscriptionEngine` protocol.
actor WhisperEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)
        case emptyResult

        var description: String {
            switch self {
            case .notPrepared: return "whisper engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            case .emptyResult: return "transcription returned no results"
            }
        }
    }

    nonisolated let name = "whisper"
    nonisolated let model: String

    private var pipe: WhisperKit?

    init(model: String) {
        self.model = model
    }

    func prepare() async throws {
        guard pipe == nil else { return }
        let config = WhisperKitConfig(
            model: model,
            verbose: false,
            logLevel: .error,
            download: true
        )
        let pipe = try await WhisperKit(config)
        self.pipe = pipe
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let pipe else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead, mirroring ParakeetEngine.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var options = DecodingOptions()
        // Strip Whisper's special tokens (<|startoftranscript|>, <|it|>,
        // <|transcribe|>, timestamp markers) from the segment text — they're
        // metadata, not speech.
        options.skipSpecialTokens = true
        if let language = Config.whisperLanguage() {
            options.language = language
            // Pin the language via a prefill prompt token instead of
            // auto-detection.
            options.usePrefillPrompt = true
        }

        let results = try await pipe.transcribe(
            audioPath: audio.path,
            decodeOptions: options
        )
        guard let result = results.first else { throw EngineError.emptyResult }

        // WhisperKit emits one segment per ~30s window plus sentence breaks;
        // drop no-speech windows and empty text so the transcript stays tidy.
        return result.segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // noSpeechProb is 0..1; WhisperKit's default noSpeechThreshold is
            // 0.6 — skip windows the model considers silence.
            if seg.noSpeechProb > 0.6 { return nil }
            return TranscriptSegment(
                start: TimeInterval(seg.start),
                end: TimeInterval(seg.end),
                text: text
            )
        }
    }

    func release() async {
        // WhisperKit holds Core ML models via ARC; dropping the reference
        // lets them deallocate from unified memory, mirroring ParakeetEngine's
        // manager.cleanup() + nil.
        pipe = nil
    }
}
