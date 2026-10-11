import XCTest
import TwitchyCore
import TwitchySources

private final class TestSecrets: SecretStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data, key: String) throws { values[key] = data }
    func delete(_ key: String) throws { values.removeValue(forKey: key) }
}
private actor TestCloud: CloudSyncTransport {
    var values: [String: SyncValue] = [:]
    func accountID() async throws -> String { "test-account" }
    func fetch() async throws -> [SyncValue] { Array(values.values) }
    func save(_ value: SyncValue) async throws -> SyncValue {
        if let remote = values[value.key], !value.supersedes(remote) { return remote }
        values[value.key] = value; return value
    }
}
final class TVStorageTests: XCTestCase {
    @MainActor func testWritableCacheAndCloudRecoveryAfterEviction() async throws {
        XCTAssertTrue(TwitchyStoragePaths.directory.path.contains("/Library/Caches/"))
        XCTAssertEqual(PersonalStore.defaultURL.deletingLastPathComponent(), TwitchyStoragePaths.directory)
        let root = TwitchyStoragePaths.directory.appendingPathComponent("Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = TestSecrets(), transport = TestCloud()
        let personalURL = root.appendingPathComponent("personal.json"), sourceURL = root.appendingPathComponent("sources.json"), journalURL = root.appendingPathComponent("sync.sealed")
        let personal = PersonalStore(url: personalURL), sources = StreamingSourceManager(url: sourceURL, secrets: keys)
        let cloud = CloudSyncStore(transport: transport, file: journalURL, secrets: keys)
        let sync = AppDataSync(personal: personal, sources: sources, cloud: cloud)
        try sync.start()
        personal.favorite("fixture")
        let source = StreamingSource(name: "Test", baseURL: URL(string: "https://source.example")!, usesAuthentication: true)
        try sources.upsert(source, credential: "test-source-token")
        await sync.sync()
        XCTAssertNil(personal.error); XCTAssertNil(sources.error); XCTAssertEqual(cloud.status, "Up to date")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(String(decoding: try Data(contentsOf: journalURL), as: UTF8.self).contains("test-source-token"))
        XCTAssertEqual(PersonalStore(url: personalURL).data.favorites, ["fixture"])
        // tvOS may evict Caches. Cloud records and Keychain must restore the configuration.
        try FileManager.default.removeItem(at: root)
        let restoredPersonal = PersonalStore(url: personalURL), restoredSources = StreamingSourceManager(url: sourceURL, secrets: keys)
        let restoredCloud = CloudSyncStore(transport: transport, file: journalURL, secrets: keys)
        let restored = AppDataSync(personal: restoredPersonal, sources: restoredSources, cloud: restoredCloud)
        try restored.start(); await restored.sync()
        XCTAssertEqual(restoredPersonal.data.favorites, ["fixture"])
        XCTAssertEqual(restoredSources.active?.id, source.id)
        XCTAssertEqual(try restoredSources.credential(for: source.id), "test-source-token")
        XCTAssertNil(restoredPersonal.error); XCTAssertEqual(restoredCloud.status, "Up to date")
    }
}
