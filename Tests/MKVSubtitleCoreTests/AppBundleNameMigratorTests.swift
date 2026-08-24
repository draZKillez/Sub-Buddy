import Foundation
import XCTest
@testable import MKVSubtitleCore

final class AppBundleNameMigratorTests: XCTestCase {
    func testOnlyLegacyBundleNamesProduceMigrationDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(
            AppBundleNameMigrator.destinationURL(for: root.appendingPathComponent("AI看剧伴侣.app")),
            root.appendingPathComponent("Sub Buddy.app", isDirectory: true)
        )
        XCTAssertNil(AppBundleNameMigrator.destinationURL(for: root.appendingPathComponent("Sub Buddy.app")))
        XCTAssertNil(AppBundleNameMigrator.destinationURL(for: root.appendingPathComponent("Unrelated.app")))
    }

    func testMigrationRenamesLegacyBundleWithoutCopyingOrDeletingContents() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("AI看剧伴侣.app", isDirectory: true)
        let marker = legacy.appendingPathComponent("Contents/marker.txt")
        try fileManager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: marker)
        defer { try? fileManager.removeItem(at: root) }

        let migrated = try XCTUnwrap(AppBundleNameMigrator.migrateIfNeeded(bundleURL: legacy))

        XCTAssertEqual(migrated, root.appendingPathComponent("Sub Buddy.app", isDirectory: true))
        XCTAssertFalse(fileManager.fileExists(atPath: legacy.path))
        XCTAssertEqual(try String(contentsOf: migrated.appendingPathComponent("Contents/marker.txt")), "preserved")
    }

    func testMigrationDoesNotOverwriteExistingSubBuddyBundle() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("AI看剧伴侣.app", isDirectory: true)
        let existing = root.appendingPathComponent("Sub Buddy.app", isDirectory: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        XCTAssertNil(try AppBundleNameMigrator.migrateIfNeeded(bundleURL: legacy))
        XCTAssertTrue(fileManager.fileExists(atPath: legacy.path))
        XCTAssertTrue(fileManager.fileExists(atPath: existing.path))
    }

    func testCurrentSubBuddyIdentifiesOnlyObsoleteLegacyCopiesWithSameBundleID() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let current = root.appendingPathComponent("Sub Buddy.app", isDirectory: true)
        let obsolete = root.appendingPathComponent("AI看剧伴侣.app", isDirectory: true)
        let newer = root.appendingPathComponent("AI Viewing Companion.app", isDirectory: true)
        let unrelated = root.appendingPathComponent("MKV Subtitle Translator.app", isDirectory: true)
        try makeBundle(at: current, identifier: "com.example.subbuddy", build: 20)
        try makeBundle(at: obsolete, identifier: "com.example.subbuddy", build: 19)
        try makeBundle(at: newer, identifier: "com.example.subbuddy", build: 21)
        try makeBundle(at: unrelated, identifier: "com.example.other", build: 10)
        defer { try? fileManager.removeItem(at: root) }

        XCTAssertEqual(
            AppBundleNameMigrator.obsoleteLegacyBundleURLs(alongside: current),
            [obsolete]
        )
    }

    func testPreferredBundleWinsOnlyWhenItIsSameAppAndNotOlder() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("AI看剧伴侣.app", isDirectory: true)
        let preferred = root.appendingPathComponent("Sub Buddy.app", isDirectory: true)
        try makeBundle(at: legacy, identifier: "com.example.subbuddy", build: 20)
        try makeBundle(at: preferred, identifier: "com.example.subbuddy", build: 20)
        defer { try? fileManager.removeItem(at: root) }

        XCTAssertTrue(AppBundleNameMigrator.preferredBundleShouldReplaceLegacy(
            legacyBundleURL: legacy,
            preferredBundleURL: preferred
        ))

        try makeBundle(at: preferred, identifier: "com.example.subbuddy", build: 19)
        XCTAssertFalse(AppBundleNameMigrator.preferredBundleShouldReplaceLegacy(
            legacyBundleURL: legacy,
            preferredBundleURL: preferred
        ))
    }

    private func makeBundle(at url: URL, identifier: String, build: Int) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleVersion": "\(build)"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }
}
