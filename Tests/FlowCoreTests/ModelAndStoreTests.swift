import XCTest
@testable import FlowCore

final class ChecksumTests: XCTestCase {
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flow-ck-\(UUID().uuidString)")
        for p in ModelLayout.requiredPaths {
            let f = root.appendingPathComponent(p)
            if p.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
                try Data("coreml \(p)".utf8).write(to: f.appendingPathComponent("coremldata.bin"))
                try FileManager.default.createDirectory(at: f.appendingPathComponent("weights"), withIntermediateDirectories: true)
                try Data([UInt8](repeating: 7, count: 1000)).write(to: f.appendingPathComponent("weights/weight.bin"))
            } else {
                try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: f)
            }
        }
        return root
    }

    func testChecksumIsStableAndOrderIndependent() throws {
        let root = try makeTree()
        let files = try ModelChecksum.scan(root)
        XCTAssertFalse(files.isEmpty)
        let a = ModelChecksum.combined(files)
        let b = ModelChecksum.combined(files.shuffled())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        // Same content in a different folder → same checksum ("Load from folder" must agree with the download).
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("flow-ck-copy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: root, to: copy)
        XCTAssertEqual(ModelChecksum.combined(try ModelChecksum.scan(copy)), a)
        // Any byte change moves it.
        try Data("x".utf8).write(to: root.appendingPathComponent(ModelLayout.requiredPaths[0]).appendingPathComponent("coremldata.bin"))
        XCTAssertNotEqual(ModelChecksum.combined(try ModelChecksum.scan(root)), a)
    }

    func testManifestRoundTripAndImport() throws {
        let root = try makeTree()
        let m = try ModelDownloader.writeManifest(at: root, source: "folder")
        let loaded = ModelManifest.load(from: root)
        XCTAssertEqual(loaded?.checksum, m.checksum)
        XCTAssertEqual(loaded?.source, "folder")
        XCTAssertTrue(ModelLayout.isComplete(at: root))
        // manifest.json itself is excluded from the scan, so rewriting doesn't change the checksum.
        XCTAssertEqual(try ModelDownloader.writeManifest(at: root, source: "folder").checksum, m.checksum)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("flow-import-\(UUID().uuidString)/parakeet-tdt-0.6b-v3")
        let imported = try ModelDownloader.importFolder(root, into: dest)
        XCTAssertEqual(imported.checksum, m.checksum)
    }

    func testMissingFilesReported() throws {
        let root = try makeTree()
        try FileManager.default.removeItem(at: root.appendingPathComponent(ModelLayout.asrFolder).appendingPathComponent("Decoder.mlmodelc"))
        XCTAssertEqual(ModelLayout.missing(at: root), ["\(ModelLayout.asrFolder)/Decoder.mlmodelc"])
        XCTAssertThrowsError(try ModelDownloader.writeManifest(at: root, source: "folder"))
    }
}

final class StoreTests: XCTestCase {
    func makeDB() throws -> FlowDatabase {
        try FlowDatabase(path: FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString).sqlite").path)
    }

    func testSeedsAndStyles() throws {
        let db = try makeDB()
        XCTAssertEqual(db.appStyle(for: "com.apple.mail").tone, "formal")
        XCTAssertEqual(db.appStyle(for: "com.tinyspeck.slackmacgap").tone, "casual")
        XCTAssertEqual(db.appStyle(for: "com.apple.Notes").format, "markdown")
        XCTAssertEqual(db.appStyle(for: "unknown.app").bundleId, "*")
        XCTAssertEqual(db.appStyle(for: nil).bundleId, "*")
        try db.deleteAppStyle(bundleId: "*")
        XCTAssertEqual(db.appStyle(for: nil).bundleId, "*")
    }

    func testDictationRoundTripSearchDelete() throws {
        let db = try makeDB()
        let d = Dictation(startedAt: Date(), durationMs: 1200, appBundleId: "a", appName: "A", rawText: "um Hello World", cleanedText: "Hello, world.",
                          insertedText: "Hello, world. ", insertMethod: "ax", sttModel: "m", cleanupBackend: "rules", cleanupModel: nil,
                          sttMs: 300, cleanupMs: 5, wordCount: 2, error: nil)
        db.record(d)
        let all = try db.dictations()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, d.id)
        XCTAssertEqual(all[0].startedAt.timeIntervalSince1970, d.startedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try db.dictations(search: "WORLD").count, 1)
        XCTAssertEqual(try db.dictations(search: "um hello").count, 1)
        XCTAssertEqual(try db.dictations(search: "nothing").count, 0)
        // Stored as ISO 8601 UTC text with fractional seconds.
        let raw = try db.queue.read { db in try String.fetchOne(db, sql: "SELECT started_at FROM dictations") }
        XCTAssertNotNil(raw)
        XCTAssertTrue(raw!.hasSuffix("Z") && raw!.contains("."), raw!)
        try db.deleteDictation(id: d.id)
        XCTAssertEqual(try db.dictations().count, 0)
    }

    func testRetentionAndDeleteAll() throws {
        let db = try makeDB()
        let old = Dictation(startedAt: Date().addingTimeInterval(-100 * 86_400), durationMs: 1, appBundleId: "a", appName: "A", rawText: nil, cleanedText: nil,
                            insertedText: nil, insertMethod: "ax", sttModel: "m", cleanupBackend: "off", cleanupModel: nil, sttMs: 0, cleanupMs: nil, wordCount: 0, error: nil)
        var fresh = old; fresh.id = UUID().uuidString; fresh.startedAt = Date()
        db.record(old); db.record(fresh)
        XCTAssertEqual(try db.purgeHistory(olderThanDays: 90), 1)
        XCTAssertEqual(try db.purgeHistory(olderThanDays: 0), 0)
        XCTAssertEqual(try db.dictations().count, 1)
        try db.deleteAllHistory()
        XCTAssertEqual(try db.dictations().count, 0)
    }

    func testDictionaryImportExportAndUseCount() throws {
        let db = try makeDB()
        XCTAssertEqual(try db.importDictionary(text: "Wolchonok | wall chunk\nGRDB\nWolchonok\n\n# comment\n"), 2)
        XCTAssertEqual(db.dictionaryEntries().count, 2)
        db.incrementUse(of: ["Wolchonok", "missing"])
        XCTAssertEqual(db.dictionaryEntries().first { $0.term == "Wolchonok" }?.useCount, 1)
        XCTAssertEqual(db.exportDictionary(), "GRDB\nWolchonok | wall chunk\n")
        XCTAssertFalse(try db.addDictionaryEntry(term: "GRDB", soundsLike: nil))
    }

    func testSnippetsLowercaseTrigger() throws {
        let db = try makeDB()
        try db.saveSnippet(Snippet(triggerPhrase: "My Sig", expansion: "x"))
        XCTAssertEqual(db.snippets().first?.triggerPhrase, "my sig")
    }
}

final class NetworkIsolationTests: XCTestCase {
    /// Only ModelDownloader.swift and OllamaCleaner.swift may touch a networking API.
    func testOnlyTwoFilesMentionNetworking() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let allowed: Set<String> = ["ModelDownloader.swift", "OllamaCleaner.swift"]
        let re = try NSRegularExpression(pattern: "URLSession|\\bNetwork\\b|NWConnection|NWPathMonitor|CFStream|CFSocket|NSURLConnection|NSStream")
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            scanned += 1
            guard !allowed.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { offenders.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 10)
        XCTAssertEqual(offenders, [], "networking API outside the two allowed files")
    }
}
