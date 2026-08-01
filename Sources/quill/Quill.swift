import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Analyze.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Run AI analysis (summary, action items, etc.) on a session's transcript.
/// Writes an Obsidian-style folder of Markdown notes inside the session
/// directory. By default uses the modules from config; `--only` overrides
/// with a comma-separated list of module IDs.
struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Run AI analysis on a session's transcript."
    )

    @Argument(help: "Session directory containing transcript.json.")
    var dir: String

    @Option(name: .long, help: "Comma-separated module IDs to run (overrides config).")
    var only: String?

    func run() throws {
        let sessionDir = URL(
            fileURLWithPath: (dir as NSString).expandingTildeInPath,
            isDirectory: true
        )
        guard FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("transcript.json").path
        ) else {
            FileHandle.standardError.write(Data(
                "no transcript.json in \(sessionDir.path)\n".utf8
            ))
            throw ExitCode(1)
        }

        let modules: [AnalysisModule]
        if let only {
            let ids = only.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let configured = Config.analysisModules()
            modules = ids.compactMap { id in configured.first { $0.id == id } }
            if modules.count != ids.count {
                let missing = ids.filter { id in !configured.contains { $0.id == id } }
                FileHandle.standardError.write(Data(
                    "unknown module(s): \(missing.joined(separator: ", "))\n".utf8
                ))
                throw ExitCode(1)
            }
        } else {
            modules = Config.analysisModules()
        }

        let coordinator = AnalysisCoordinator()
        let sem = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()
        Task {
            do {
                try await coordinator.analyzeSession(sessionDir, modules: modules)
            } catch {
                errorBox.error = error
            }
            sem.signal()
        }
        // Pump the main run loop while the async work runs on the
        // cooperative thread pool — Analyze is a CLI, not a daemon, so we
        // need to keep the process alive until the Task completes.
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        if let error = errorBox.error {
            FileHandle.standardError.write(Data(
                "analysis failed: \(error)\n".utf8
            ))
            throw ExitCode(1)
        }
    }
}

/// Thread-safe box for passing an error out of a `Task` back to the
/// synchronous `run()` caller. The error is written once before the
/// semaphore signals and read once after, so the race is benign.
final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    /// True while a recording is starting up (engine start runs on a background
    /// queue). Prevents the user from double-clicking "Start recording" and
    /// launching a second session before the first engine has settled.
    private var starting = false
    /// Persisted mic device UID (nil = system default). Resolved to an
    /// AudioDeviceID at recording start, since the id is only valid for the
    /// current process lifetime.
    private var selectedMicUID: String?

    init(root: URL) {
        self.root = root
        let persistedUID = State.micDeviceUID()
        self.selectedMicUID = persistedUID
        menuBar.setSelectedMicUID(persistedUID)
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onInputDeviceSelected = { [weak self] uid in
            self?.selectInputDevice(uid)
        }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.setAnalysisStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showAnalysis(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Persist the user's mic choice. The actual AudioDeviceID is resolved at
    /// the next recording start, so unplugging a selected device between
    /// recordings just falls back to the system default rather than failing.
    private func selectInputDevice(_ uid: String?) {
        selectedMicUID = uid
        State.setMicDeviceUID(uid)
        if let uid {
            FileHandle.standardError.write(Data(
                "input device → \(uid)\n".utf8
            ))
        } else {
            FileHandle.standardError.write(Data(
                "input device → system default\n".utf8
            ))
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        starting = false
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        // Ignore while a recording is starting up — the engine start runs on
        // a background queue and session isn't set yet.
        guard !starting else { return }
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        starting = true

        let resolvedID = selectedMicUID.flatMap { AudioDevices.deviceID(forUID: $0) }
        if let selectedMicUID, resolvedID == nil {
            FileHandle.standardError.write(Data(
                "warning: selected mic device \(selectedMicUID) not found — using system default\n".utf8
            ))
        }
        // If the resolved device IS the system default, treat it as "no
        // preference". Passing a non-nil deviceID that equals the default
        // to MicRecorder is a no-op for the swap, but keeps the recorder on
        // a code path where AVAudioEngine's input node binding can behave
        // differently from the nil (system default) path — occasionally
        // producing silence. Collapsing to nil makes the two paths
        // literally identical.
        let deviceID = (resolvedID == AudioDevices.defaultInputDeviceID()) ? nil : resolvedID

        // Create the session folder synchronously (fast, filesystem only).
        // The actual engine start runs in the Task below so a blocking
        // AVAudioEngine.start() doesn't freeze the UI.
        let newSession: RecordingSession
        do {
            newSession = try RecordingSession(root: root, micDeviceID: deviceID)
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            starting = false
            return
        }

        let dir = newSession.dir
        Task {
            do {
                try await newSession.start()
                self.session = newSession
                self.starting = false
                FileHandle.standardError.write(Data("● recording → \(dir.path)\n".utf8))
                self.menuBar.update(recording: true, elapsed: "0:00")
                self.ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            } catch {
                self.starting = false
                FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
                notifyUser(title: "quill — recording failed", body: "\(error)")
            }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func showAnalysis(_ status: AnalysisCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateAnalysis(nil)
        case .analyzing(let session, let module):
            menuBar.updateAnalysis("analyzing \(session) · \(module)")
        case .failed(let session):
            menuBar.updateAnalysis("analysis failed · \(session)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
