import Foundation
import Testing
@testable import DakaCore

struct DakaStoreTests {
    @Test func savesAndLoadsConfigAndRecordsFromSQLite() throws {
        let directory = try temporaryDirectory()
        let paths = try DakaPaths(baseDirectory: directory)
        let store = try DakaStore(paths: paths)
        let config = AppConfig(
            rule: TimerRule(name: "Office", matchMode: .all, conditions: [.screenUnlocked, .powerConnected]),
            evaluationIntervalSeconds: 30,
            targetDurationSeconds: 8 * 60 * 60
        )
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let last = Date(timeIntervalSince1970: 1_779_282_800)
        let record = DailyRecord(date: "2026-05-20", firstMatchedAt: first, lastMatchedAt: last)

        try store.saveConfig(config)
        try store.saveRecords([record])

        let reloaded = try DakaStore(paths: paths)

        #expect(try reloaded.loadConfig() == config)
        #expect(try reloaded.loadRecords() == [record])
        #expect(FileManager.default.fileExists(atPath: paths.databaseURL.path))
    }

    @Test func migratesLegacyJSONIntoSQLite() throws {
        let directory = try temporaryDirectory()
        let paths = try DakaPaths(baseDirectory: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        let config = AppConfig(
            rule: TimerRule(name: "Legacy", matchMode: .any, conditions: [.screenUnlocked]),
            evaluationIntervalSeconds: 45,
            targetDurationSeconds: 10.5 * 60 * 60
        )
        let record = DailyRecord(
            date: "2026-05-20",
            firstMatchedAt: Date(timeIntervalSince1970: 1_779_250_400),
            lastMatchedAt: Date(timeIntervalSince1970: 1_779_282_800)
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(config).write(to: paths.configURL)
        try encoder.encode([record]).write(to: paths.recordsURL)

        let store = try DakaStore(paths: paths)

        #expect(try store.loadConfig() == config)
        #expect(try store.loadRecords() == [record])
    }

    @Test func migratesLegacyRecordsEvenWhenConfigAlreadyExists() throws {
        let directory = try temporaryDirectory()
        let paths = try DakaPaths(baseDirectory: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = DailyRecord(
            date: "2026-05-20",
            firstMatchedAt: Date(timeIntervalSince1970: 1_779_250_400),
            lastMatchedAt: Date(timeIntervalSince1970: 1_779_282_800)
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode([record]).write(to: paths.recordsURL)

        let firstStore = try DakaStore(paths: paths)
        try firstStore.saveConfig(.default)

        let reloaded = try DakaStore(paths: paths)

        #expect(try reloaded.loadRecords() == [record])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DakaStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
