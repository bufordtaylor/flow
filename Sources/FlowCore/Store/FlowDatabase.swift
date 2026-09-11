import Foundation
import GRDB

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()
private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private func decodeISO(_ v: DatabaseValue) -> Date? {
    guard let s = String.fromDatabaseValue(v) else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

/// Every record stores timestamps as ISO 8601 UTC text with fractional seconds and snake_case columns.
public protocol FlowRecord: Codable, FetchableRecord, PersistableRecord {}
extension FlowRecord {
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .custom { isoFractional.string(from: $0) } }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .custom { decodeISO($0) } }
}

extension Dictation: FlowRecord {
    public static let databaseTableName = "dictations"
}
extension DictionaryEntry: FlowRecord {
    public static let databaseTableName = "dictionary_entries"
}
extension AppStyle: FlowRecord {
    public static let databaseTableName = "app_styles"
}
extension Snippet: FlowRecord {
    public static let databaseTableName = "snippets"
}

public struct WeekStats: Sendable, Equatable {
    public var rows: Int
    public var words: Int
    public init(rows: Int, words: Int) { self.rows = rows; self.words = words }
}

/// SQLite at ~/Library/Application Support/Flow/flow.sqlite, managed with GRDB migrations.
public final class FlowDatabase: PipelineStore, @unchecked Sendable {
    public let queue: DatabaseQueue

    public static var defaultURL: URL { Settings.supportDirectory.appendingPathComponent("flow.sqlite") }

    public convenience init() throws {
        try FileManager.default.createDirectory(at: Settings.supportDirectory, withIntermediateDirectories: true)
        try self.init(path: Self.defaultURL.path)
    }

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(queue)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "dictations") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at", .text).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("app_bundle_id", .text).notNull()
                t.column("app_name", .text).notNull()
                t.column("raw_text", .text)
                t.column("cleaned_text", .text)
                t.column("inserted_text", .text)
                t.column("insert_method", .text).notNull()
                t.column("stt_model", .text).notNull()
                t.column("cleanup_backend", .text).notNull()
                t.column("cleanup_model", .text)
                t.column("stt_ms", .integer).notNull()
                t.column("cleanup_ms", .integer)
                t.column("word_count", .integer).notNull()
                t.column("error", .text)
            }
            try db.create(index: "dictations_started_at", on: "dictations", columns: ["started_at"])
            try db.create(table: "dictionary_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("term", .text).notNull().unique()
                t.column("sounds_like", .text)
                t.column("use_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
            }
            try db.create(table: "app_styles") { t in
                t.column("bundle_id", .text).primaryKey()
                t.column("app_name", .text).notNull()
                t.column("tone", .text).notNull()
                t.column("hint", .text).notNull()
                t.column("format", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(table: "snippets") { t in
                t.column("id", .text).primaryKey()
                t.column("trigger_phrase", .text).notNull().unique()
                t.column("expansion", .text).notNull()
                t.column("created_at", .text).notNull()
            }
            for s in FlowDatabase.seedStyles { try s.insert(db) }
        }
        return m
    }

    public static let seedStyles: [AppStyle] = {
        let slack = "Slack message. Short. No sign-off. A lowercase first letter is fine for one-liners."
        let term = "Terminal. Output one line. No trailing punctuation. Never wrap in quotes or code fences."
        let notes = "Notes. Use markdown lists and headings when the speaker enumerates."
        return [
            AppStyle(bundleId: "*", appName: "Default", tone: "neutral", hint: "Everyday written English.", format: "plain"),
            AppStyle(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", tone: "casual", hint: slack, format: "plain"),
            AppStyle(bundleId: "com.apple.MobileSMS", appName: "Messages", tone: "casual", hint: "Text message. Very short. No period on a single short sentence.", format: "plain"),
            AppStyle(bundleId: "com.apple.mail", appName: "Mail", tone: "formal", hint: "Email. Complete sentences. Keep greetings and sign-offs the speaker says.", format: "plain"),
            AppStyle(bundleId: "com.apple.Terminal", appName: "Terminal", tone: "neutral", hint: term, format: "plain"),
            AppStyle(bundleId: "com.googlecode.iterm2", appName: "iTerm2", tone: "neutral", hint: term, format: "plain"),
            AppStyle(bundleId: "com.apple.Notes", appName: "Notes", tone: "neutral", hint: notes, format: "markdown"),
            AppStyle(bundleId: "notion.id", appName: "Notion", tone: "neutral", hint: notes, format: "markdown"),
            AppStyle(bundleId: "md.obsidian", appName: "Obsidian", tone: "neutral", hint: notes, format: "markdown"),
        ]
    }()

    // MARK: PipelineStore

    public func appStyle(for bundleId: String?) -> AppStyle {
        (try? queue.read { db in
            if let b = bundleId, let s = try AppStyle.fetchOne(db, key: b) { return s }
            return try AppStyle.fetchOne(db, key: "*")
        }) ?? .fallback
    }

    public func dictionaryEntries() -> [DictionaryEntry] {
        (try? queue.read { db in try DictionaryEntry.order(Column("term")).fetchAll(db) }) ?? []
    }

    public func snippets() -> [Snippet] {
        (try? queue.read { db in try Snippet.order(Column("trigger_phrase")).fetchAll(db) }) ?? []
    }

    public func record(_ d: Dictation) {
        do { try queue.write { db in try d.insert(db) } }
        catch { Log.error("store", "record failed: \(error)") }
    }

    public func incrementUse(of terms: [String]) {
        guard !terms.isEmpty else { return }
        try? queue.write { db in
            for t in terms {
                try db.execute(sql: "UPDATE dictionary_entries SET use_count = use_count + 1 WHERE term = ?", arguments: [t])
            }
        }
    }

    // MARK: History

    public func dictations(search: String = "", limit: Int = 2000) throws -> [Dictation] {
        try queue.read { db in
            var q = Dictation.order(Column("started_at").desc).limit(limit)
            let s = search.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty {
                let like = "%\(s.lowercased())%"
                q = q.filter(sql: "lower(coalesce(raw_text,'')) LIKE ? OR lower(coalesce(cleaned_text,'')) LIKE ?", arguments: [like, like])
            }
            return try q.fetchAll(db)
        }
    }

    public func deleteDictation(id: String) throws {
        _ = try queue.write { db in try Dictation.deleteOne(db, key: id) }
    }

    public func deleteAllHistory() throws {
        try queue.write { db in _ = try Dictation.deleteAll(db) }
        try queue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
    }

    public func purgeHistory(olderThanDays days: Int, now: Date = Date()) throws -> Int {
        guard days > 0 else { return 0 }
        let cutoff = isoFractional.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        return try queue.write { db in try Dictation.filter(Column("started_at") < cutoff).deleteAll(db) }
    }

    public func weekStats(now: Date = Date()) -> WeekStats {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let cutoff = isoFractional.string(from: start)
        return (try? queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT count(*) AS n, coalesce(sum(word_count),0) AS w FROM dictations WHERE started_at >= ?", arguments: [cutoff])
            return WeekStats(rows: row?["n"] ?? 0, words: row?["w"] ?? 0)
        }) ?? WeekStats(rows: 0, words: 0)
    }

    // MARK: Dictionary

    public func addDictionaryEntry(term: String, soundsLike: String?) throws -> Bool {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return try queue.write { db in
            if try DictionaryEntry.filter(Column("term") == t).fetchCount(db) > 0 { return false }
            let sl = soundsLike?.trimmingCharacters(in: .whitespaces)
            try DictionaryEntry(term: t, soundsLike: (sl?.isEmpty ?? true) ? nil : sl).insert(db)
            return true
        }
    }

    public func updateDictionaryEntry(_ e: DictionaryEntry) throws {
        try queue.write { db in try e.update(db) }
    }

    public func deleteDictionaryEntry(id: String) throws {
        _ = try queue.write { db in try DictionaryEntry.deleteOne(db, key: id) }
    }

    /// One term per line, optional `term | sounds like`. Returns how many were added; duplicates are skipped.
    public func importDictionary(text: String) throws -> Int {
        var added = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let term = parts.first, !term.isEmpty, !term.hasPrefix("#") else { continue }
            if try addDictionaryEntry(term: term, soundsLike: parts.count > 1 ? parts[1] : nil) { added += 1 }
        }
        return added
    }

    public func exportDictionary() -> String {
        dictionaryEntries().map { e in
            if let s = e.soundsLike, !s.isEmpty { return "\(e.term) | \(s)" }
            return e.term
        }.joined(separator: "\n") + "\n"
    }

    // MARK: App styles

    public func appStyles() -> [AppStyle] {
        (try? queue.read { db in try AppStyle.order(Column("app_name")).fetchAll(db) }) ?? []
    }

    public func saveAppStyle(_ s: AppStyle) throws {
        var copy = s
        copy.updatedAt = Date()
        try queue.write { db in try copy.save(db) }
    }

    public func deleteAppStyle(bundleId: String) throws {
        guard bundleId != "*" else { return }
        _ = try queue.write { db in try AppStyle.deleteOne(db, key: bundleId) }
    }

    // MARK: Snippets

    public func saveSnippet(_ s: Snippet) throws {
        try queue.write { db in try s.save(db) }
    }

    public func deleteSnippet(id: String) throws {
        _ = try queue.write { db in try Snippet.deleteOne(db, key: id) }
    }
}
