import Combine
import Foundation

struct ClaudeStatusLineBridgePaths: Equatable, Sendable {
    let settingsURL: URL
    let scriptURL: URL
    let backupURL: URL
    let cacheURL: URL

    static var `default`: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            scriptURL: home.appendingPathComponent(".claude/deskbar-statusline-bridge.sh"),
            backupURL: home.appendingPathComponent(".claude/deskbar-statusline-backup.json"),
            cacheURL: home
                .appendingPathComponent("Library/Caches/DeskBar", isDirectory: true)
                .appendingPathComponent("claude-code-rate-limits.json")
        )
    }
}

enum ClaudeStatusLineBridgeInstallerError: Error, LocalizedError {
    case invalidSettings
    case unsupportedExistingStatusLine
    case existingBackupRequiresRecovery
    case backupMissing
    case configurationChanged
    case symbolicLinkSettingsUnsupported
    case existingBridgeArtifactRequiresRecovery

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            "Claude Code settings.json is not a valid JSON object. DeskBar left it unchanged."
        case .unsupportedExistingStatusLine:
            "The existing Claude Code status line is not a documented command configuration, so DeskBar left it unchanged."
        case .existingBackupRequiresRecovery:
            "A previous DeskBar status-line backup exists. Restore or remove it before installing again."
        case .backupMissing:
            "DeskBar cannot safely restore the previous status line because its backup is missing."
        case .configurationChanged:
            "The Claude Code status line changed after DeskBar installed its bridge, so DeskBar left the new configuration untouched."
        case .symbolicLinkSettingsUnsupported:
            "Claude Code settings.json is a symbolic link. DeskBar left it unchanged to avoid replacing a managed dotfile."
        case .existingBridgeArtifactRequiresRecovery:
            "A DeskBar bridge script already exists without a matching installation backup. Recover or remove it before installing again."
        }
    }
}

@MainActor
final class ClaudeStatusLineBridgeInstaller: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case installed
        case needsRecovery(String)
        case unavailable(String)
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var lastError: String?

    let paths: ClaudeStatusLineBridgePaths
    private let fileManager: FileManager
    private let settingsWriteOverride: (([String: Any]) throws -> Void)?

    init(
        paths: ClaudeStatusLineBridgePaths = .default,
        fileManager: FileManager = .default,
        settingsWriteOverride: (([String: Any]) throws -> Void)? = nil
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.settingsWriteOverride = settingsWriteOverride
        refresh()
    }

    func refresh() {
        do {
            let settings = try readSettings()
            let configured = currentStatusLineCommand(in: settings) == bridgeCommand
            let hasScript = fileManager.isExecutableFile(atPath: paths.scriptURL.path)
            let hasBackup = fileManager.fileExists(atPath: paths.backupURL.path)

            if configured, hasScript, hasBackup {
                state = .installed
            } else if configured || hasScript || hasBackup {
                state = .needsRecovery(
                    "DeskBar found an incomplete Claude Code status-line bridge installation."
                )
            } else {
                state = .notInstalled
            }
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    func install() {
        lastError = nil
        do {
            try performInstall()
            refresh()
        } catch {
            lastError = error.localizedDescription
            refresh()
        }
    }

    func uninstall() {
        lastError = nil
        do {
            try performUninstall()
            refresh()
        } catch {
            lastError = error.localizedDescription
            refresh()
        }
    }

    func clearError() {
        lastError = nil
    }

    private var bridgeCommand: String {
        Self.shellQuote(paths.scriptURL.path)
    }

    private func performInstall() throws {
        var settings = try readSettings()
        if currentStatusLineCommand(in: settings) == bridgeCommand {
            guard fileManager.fileExists(atPath: paths.backupURL.path) else {
                throw ClaudeStatusLineBridgeInstallerError.backupMissing
            }
            let backup = try readBackup()
            try writeBridgeScript(previousCommand: backup.previousCommand)
            return
        }

        guard !fileManager.fileExists(atPath: paths.backupURL.path) else {
            throw ClaudeStatusLineBridgeInstallerError.existingBackupRequiresRecovery
        }
        guard !fileManager.fileExists(atPath: paths.scriptURL.path) else {
            throw ClaudeStatusLineBridgeInstallerError.existingBridgeArtifactRequiresRecovery
        }

        let originalStatusLine = settings["statusLine"]
        let originalSettings = settings
        let previousCommand = try validatedPreviousCommand(from: originalStatusLine)
        let backup = try Backup(originalStatusLine: originalStatusLine, previousCommand: previousCommand)
        let cacheDirectory = paths.cacheURL.deletingLastPathComponent()
        let cacheDirectoryExisted = fileManager.fileExists(atPath: cacheDirectory.path)
        let cacheExisted = fileManager.fileExists(atPath: paths.cacheURL.path)

        do {
            try createPrivateDirectory(at: paths.backupURL.deletingLastPathComponent())
            try createPrivateDirectory(at: cacheDirectory)
            try writeBackup(backup)
            try writeBridgeScript(previousCommand: previousCommand)

            var bridgedStatusLine = (originalStatusLine as? [String: Any]) ?? [:]
            bridgedStatusLine["type"] = "command"
            bridgedStatusLine["command"] = bridgeCommand
            settings["statusLine"] = bridgedStatusLine
            try writeSettings(settings)

            // Never show a reading captured by an older bridge installation.
            try? removeFileIfPresent(at: paths.cacheURL)
        } catch {
            // The settings change is the commit point. Before it succeeds, every
            // DeskBar-owned artifact created by this attempt is safe to roll back.
            var canRemoveBridgeArtifacts = false
            if let currentSettings = try? readSettings() {
                if currentStatusLineCommand(in: currentSettings) == bridgeCommand {
                    // writeSettings can fail after its atomic replacement succeeds
                    // (for example while restoring permissions), so restore the
                    // original configuration before removing its command target.
                    canRemoveBridgeArtifacts = (try? writeSettingsDirectly(originalSettings)) != nil
                } else {
                    canRemoveBridgeArtifacts = true
                }
            }

            if canRemoveBridgeArtifacts {
                try? removeFileIfPresent(at: paths.backupURL)
                try? removeFileIfPresent(at: paths.scriptURL)
                if !cacheExisted {
                    try? removeFileIfPresent(at: paths.cacheURL)
                }
                if !cacheDirectoryExisted {
                    try? fileManager.removeItem(at: cacheDirectory)
                }
            }
            throw error
        }
    }

    private func performUninstall() throws {
        var settings = try readSettings()
        let currentCommand = currentStatusLineCommand(in: settings)
        if currentCommand != bridgeCommand {
            let backup = try readBackup()
            guard currentCommand == backup.previousCommand else {
                throw ClaudeStatusLineBridgeInstallerError.configurationChanged
            }
            try removeFileIfPresent(at: paths.cacheURL)
            try removeFileIfPresent(at: paths.scriptURL)
            try removeFileIfPresent(at: paths.backupURL)
            return
        }

        let backup = try readBackup()
        if let originalStatusLine = try backup.originalStatusLine() as? [String: Any],
           var currentStatusLine = settings["statusLine"] as? [String: Any] {
            currentStatusLine["type"] = originalStatusLine["type"]
            currentStatusLine["command"] = originalStatusLine["command"]
            settings["statusLine"] = currentStatusLine
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        // Clear the provider cache before disconnecting the bridge. If this fails,
        // settings remain installed and uninstall can be retried safely.
        try removeFileIfPresent(at: paths.cacheURL)
        try writeSettings(settings)

        if fileManager.fileExists(atPath: paths.scriptURL.path) {
            try fileManager.removeItem(at: paths.scriptURL)
        }
        if fileManager.fileExists(atPath: paths.backupURL.path) {
            try fileManager.removeItem(at: paths.backupURL)
        }
    }

    private func readSettings() throws -> [String: Any] {
        guard !isSymbolicLink(at: paths.settingsURL) else {
            throw ClaudeStatusLineBridgeInstallerError.symbolicLinkSettingsUnsupported
        }
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: paths.settingsURL)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else {
            throw ClaudeStatusLineBridgeInstallerError.invalidSettings
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        if let settingsWriteOverride {
            try settingsWriteOverride(settings)
            return
        }
        try writeSettingsDirectly(settings)
    }

    private func writeSettingsDirectly(_ settings: [String: Any]) throws {
        guard !isSymbolicLink(at: paths.settingsURL) else {
            throw ClaudeStatusLineBridgeInstallerError.symbolicLinkSettingsUnsupported
        }
        try createPrivateDirectory(at: paths.settingsURL.deletingLastPathComponent())
        let existingPermissions = try? fileManager.attributesOfItem(
            atPath: paths.settingsURL.path
        )[.posixPermissions]
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: paths.settingsURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: existingPermissions ?? 0o600],
            ofItemAtPath: paths.settingsURL.path
        )
    }

    private func validatedPreviousCommand(from statusLine: Any?) throws -> String? {
        guard let statusLine else { return nil }
        guard let configuration = statusLine as? [String: Any],
              configuration["type"] as? String == "command",
              let command = configuration["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeStatusLineBridgeInstallerError.unsupportedExistingStatusLine
        }
        return command
    }

    private func currentStatusLineCommand(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func writeBridgeScript(previousCommand: String?) throws {
        try createPrivateDirectory(at: paths.scriptURL.deletingLastPathComponent())
        let script = Self.bridgeScript(cacheURL: paths.cacheURL, previousCommand: previousCommand)
        try Data(script.utf8).write(to: paths.scriptURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.scriptURL.path
        )
    }

    private func createPrivateDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func removeFileIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) || isSymbolicLink(at: url) else { return }
        try fileManager.removeItem(at: url)
    }

    private func writeBackup(_ backup: Backup) throws {
        let data = try JSONEncoder().encode(backup)
        try data.write(to: paths.backupURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.backupURL.path
        )
    }

    private func readBackup() throws -> Backup {
        guard fileManager.fileExists(atPath: paths.backupURL.path) else {
            throw ClaudeStatusLineBridgeInstallerError.backupMissing
        }
        return try JSONDecoder().decode(Backup.self, from: Data(contentsOf: paths.backupURL))
    }

    private static func bridgeScript(cacheURL: URL, previousCommand: String?) -> String {
        let cacheDirectory = shellQuote(cacheURL.deletingLastPathComponent().path)
        let cacheFile = shellQuote(cacheURL.path)
        let previousStatusLine = previousCommand.map { command in
            "printf '%s' \"$input\" | /bin/sh -c \(shellQuote(command))\nexit $?"
        } ?? "exit 0"

        return """
        #!/bin/sh
        # DeskBar Claude Code bridge: caches only the documented rate_limits object.
        umask 077
        input=$(/bin/cat)
        cache_directory=\(cacheDirectory)
        cache_file=\(cacheFile)

        if /bin/mkdir -p "$cache_directory" 2>/dev/null; then
            temporary_file=$(/usr/bin/mktemp "$cache_directory/.claude-rate-limits.XXXXXX" 2>/dev/null || true)
            if [ -n "$temporary_file" ]; then
                if printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o "$temporary_file" - 2>/dev/null; then
                    /bin/chmod 600 "$temporary_file"
                    /bin/mv -f "$temporary_file" "$cache_file"
                else
                    /bin/rm -f "$temporary_file"
                fi
            fi
        fi

        \(previousStatusLine)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct Backup: Codable {
        let schemaVersion: Int
        let originalStatusLineData: Data?
        let previousCommand: String?

        init(originalStatusLine: Any?, previousCommand: String?) throws {
            schemaVersion = 1
            self.previousCommand = previousCommand
            if let originalStatusLine {
                originalStatusLineData = try JSONSerialization.data(
                    withJSONObject: originalStatusLine,
                    options: [.fragmentsAllowed]
                )
            } else {
                originalStatusLineData = nil
            }
        }

        func originalStatusLine() throws -> Any? {
            guard let originalStatusLineData else { return nil }
            return try JSONSerialization.jsonObject(
                with: originalStatusLineData,
                options: [.fragmentsAllowed]
            )
        }
    }
}
