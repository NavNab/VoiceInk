import Foundation
import SQLite3

/// Read-only view of the VoiceInk preferences that affect file transcription.
/// Absent keys fall back to the defaults the app registers in `AppDefaults`.
struct AppSettings {
    static let appDomain = "com.prakashjoshipax.VoiceInk"
    static let defaultFillerWords = [
        "uh", "um", "uhm", "umm", "uhh", "uhhh",
        "hmm", "hm", "mmm", "mm", "mh", "ehh",
    ]

    var vadEnabled = true
    var textFormattingEnabled = true
    var removeFillerWords = true
    var fillerWords = AppSettings.defaultFillerWords
    var removePunctuation = false
    var lowercase = false

    static func load() -> AppSettings {
        var settings = AppSettings()
        settings.vadEnabled = bool("IsVADEnabled") ?? settings.vadEnabled
        settings.textFormattingEnabled = bool("IsTextFormattingEnabled") ?? settings.textFormattingEnabled
        settings.removeFillerWords = bool("RemoveFillerWords") ?? settings.removeFillerWords
        settings.removePunctuation = bool("RemovePunctuation") ?? settings.removePunctuation
        settings.lowercase = bool("LowercaseTranscription") ?? settings.lowercase
        if let words = CFPreferencesCopyAppValue("FillerWords" as CFString, appDomain as CFString) as? [String] {
            settings.fillerWords = words
        }
        return settings
    }

    private static func bool(_ key: String) -> Bool? {
        let value = CFPreferencesCopyAppValue(key as CFString, appDomain as CFString)
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return (string as NSString).boolValue
        }
        return nil
    }
}

struct ReplacementRule {
    let originalText: String
    let replacementText: String
}

/// Loads enabled word replacements from the app's dictionary store without opening it:
/// the store and its WAL/SHM side files are copied to a private directory and the copy
/// is read with SQLite in read-only mode.
enum DictionaryStore {
    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppSettings.appDomain)
            .appendingPathComponent("dictionary.store")
    }

    enum StoreError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "Cannot read word replacements: \(detail)"
            }
        }
    }

    static func loadReplacements(from storeURL: URL, tempDirectory: URL) throws -> [ReplacementRule] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

        let copyDirectory = tempDirectory.appendingPathComponent("dictionary-\(UUID().uuidString)")
        try fileManager.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: copyDirectory) }

        let copyURL = copyDirectory.appendingPathComponent("dictionary.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: URL(fileURLWithPath: copyURL.path + suffix))
            }
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(copyURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(database)
            throw StoreError.unreadable(message)
        }
        defer { sqlite3_close(database) }

        let query = "SELECT ZORIGINALTEXT, ZREPLACEMENTTEXT FROM ZWORDREPLACEMENT WHERE ZISENABLED = 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.unreadable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var rules: [ReplacementRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let original = sqlite3_column_text(statement, 0),
                  let replacement = sqlite3_column_text(statement, 1) else { continue }
            rules.append(ReplacementRule(originalText: String(cString: original), replacementText: String(cString: replacement)))
        }
        return rules
    }
}
