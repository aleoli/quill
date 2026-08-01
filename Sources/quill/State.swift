import Foundation

/// Lightweight runtime state, kept separate from the user's `config.json` so
/// we never rewrite or reformat their hand-edited config. Today this holds
/// only the last-selected microphone device UID; future UI-driven settings
/// (volume, default prompt, …) can land here without touching Config.
///
/// File: `~/.config/quill/state.json`
///
///     { "mic_device_uid": "AppleUSBAudioEngine:Builtin:..." }
///
/// A missing or malformed file is treated as "no preference" — quill falls
/// back to the system default input device.
enum State {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/state.json")

    /// The persisted mic device UID, or nil if unset / unreadable. nil means
    /// "follow the system default".
    static func micDeviceUID() -> String? {
        guard let dict = load(), let uid = dict["mic_device_uid"] as? String,
              !uid.isEmpty else { return nil }
        return uid
    }

    /// Persist the mic device UID. Pass nil to clear (revert to system default).
    /// Writes atomically so a crash mid-write can't corrupt the file.
    static func setMicDeviceUID(_ uid: String?) {
        var dict = load() ?? [:]
        if let uid, !uid.isEmpty {
            dict["mic_device_uid"] = uid
        } else {
            dict.removeValue(forKey: "mic_device_uid")
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        try? data.write(to: path, options: .atomic)
    }

    /// Parse the state file. A malformed file is reported on stderr rather
    /// than silently ignored — same posture as Config.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring state\n".utf8
            ))
            return nil
        }
        return json
    }
}
