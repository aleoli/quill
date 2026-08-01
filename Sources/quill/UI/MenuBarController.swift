import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let analysisLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let inputDeviceItem: NSMenuItem
    private let inputDeviceMenu = NSMenu()

    /// Currently selected mic device UID, or nil for system default. Drives
    /// the checkmark in the submenu; updated by the controller when the user
    /// picks a device or when state is loaded at startup.
    private var selectedMicUID: String?

    /// Mirrors the recording flag so `menuWillOpen` can disable device
    /// switching mid-session (a hot device swap would tear down an active
    /// engine graph). Updated from `update(recording:elapsed:)`.
    private var recording = false

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Called with nil for "system default" or a stable device UID. The
    /// controller persists the choice and resolves it to an AudioDeviceID at
    /// the next recording start.
    var onInputDeviceSelected: ((String?) -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        analysisLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        analysisLabel.isEnabled = false
        analysisLabel.isHidden = true
        menu.addItem(analysisLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        inputDeviceItem = NSMenuItem(
            title: "Input device",
            action: nil,
            keyEquivalent: ""
        )
        inputDeviceItem.submenu = inputDeviceMenu
        menu.addItem(inputDeviceItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        // All stored properties are initialized — finish NSObject init before
        // any `self` references (targets, delegates) below.
        super.init()

        for item in [toggleItem, openFolder, quit] {
            item.target = self
        }

        // We rebuild the device list every time the submenu opens so
        // hot-plugged devices appear without restarting quill.
        inputDeviceMenu.delegate = self
        // Also rebuild when the top-level menu opens — covers the case where
        // the submenu was already shown once and the user reopens the parent.
        menu.delegate = self

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Set the initial selection from persisted state. Called once by the
    /// controller after wiring callbacks. Does not fire `onInputDeviceSelected`.
    func setSelectedMicUID(_ uid: String?) {
        selectedMicUID = uid
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Only rebuild when the device submenu (or its parent) opens —
        // rebuilding on every parent open is cheap and keeps the checkmark in
        // sync if selection changed elsewhere.
        rebuildDeviceMenu()
    }

    // MARK: - Device submenu

    /// Rebuild the input-device submenu from the current Core Audio device
    /// list. "System default" is always first; each device shows its name and
    /// a checkmark when it matches the persisted selection. All items are
    /// disabled while recording — switching devices mid-session would require
    /// tearing down the live engine graph.
    private func rebuildDeviceMenu() {
        inputDeviceMenu.removeAllItems()

        let defaultItem = NSMenuItem(
            title: "System default",
            action: #selector(deviceSelected(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = nil
        defaultItem.state = (selectedMicUID == nil) ? .on : .off
        defaultItem.isEnabled = !recording
        inputDeviceMenu.addItem(defaultItem)

        let devices = AudioDevices.inputDevices()
        if !devices.isEmpty {
            inputDeviceMenu.addItem(.separator())
        }
        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(deviceSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = (device.uid == selectedMicUID) ? .on : .off
            item.isEnabled = !recording
            inputDeviceMenu.addItem(item)
        }

        if devices.isEmpty {
            let empty = NSMenuItem(title: "(no input devices)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            inputDeviceMenu.addItem(empty)
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        self.recording = recording
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Show analysis progress/failure as a third status line in the menu;
    /// nil hides it. Independent of transcription — analysis runs after the
    /// transcript is written, and a new recording can start meanwhile.
    func updateAnalysis(_ text: String?) {
        analysisLabel.title = text ?? ""
        analysisLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }

    /// A device submenu item was clicked. `representedObject` is nil for
    /// "System default" or a stable device UID otherwise. Updates the local
    /// selection so the checkmark is correct on the next rebuild, then
    /// forwards to the controller for persistence + session wiring.
    @objc private func deviceSelected(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        selectedMicUID = uid
        onInputDeviceSelected?(uid)
    }
}
