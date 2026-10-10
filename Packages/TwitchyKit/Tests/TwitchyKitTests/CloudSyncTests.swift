import Foundation
import Testing
@testable import TwitchyCore
@testable import TwitchySources
@testable import TwitchyAPI

actor FixtureCloud: CloudSyncTransport {
    var records: [String: SyncValue] = [:]
    var online = true
    var account = "fixture-account"
    func setOnline(_ value: Bool) { online = value }
    func setAccount(_ value: String) { account = value }
    func accountID() async throws -> String { guard online else { throw URLError(.notConnectedToInternet) }; return account }
    func fetch() async throws -> [SyncValue] { guard online else { throw URLError(.notConnectedToInternet) }; return Array(records.values) }
    func save(_ value: SyncValue) async throws -> SyncValue {
        guard online else { throw URLError(.notConnectedToInternet) }
        if let remote = records[value.key], !value.supersedes(remote) { return remote }
        records[value.key] = value; return value
    }
}

@Test @MainActor func cloudTwoDevicesMergeOfflineEditsSecretsAndDeletes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = FixtureCloud()
    let keysA = MemorySecrets(), keysB = MemorySecrets()
    let personalA = PersonalStore(url: directory.appendingPathComponent("a/personal.json"))
    let personalB = PersonalStore(url: directory.appendingPathComponent("b/personal.json"))
    let sourcesA = StreamingSourceManager(url: directory.appendingPathComponent("a/sources.json"), secrets: keysA)
    let sourcesB = StreamingSourceManager(url: directory.appendingPathComponent("b/sources.json"), secrets: keysB)
    let cloudA = CloudSyncStore(transport: transport, file: directory.appendingPathComponent("a/sync.sealed"), secrets: keysA)
    let cloudB = CloudSyncStore(transport: transport, file: directory.appendingPathComponent("b/sync.sealed"), secrets: keysB)
    let a = AppDataSync(personal: personalA, sources: sourcesA, cloud: cloudA)
    let b = AppDataSync(personal: personalB, sources: sourcesB, cloud: cloudB)
    try a.start(); try b.start()
    let source = StreamingSource(name: "Test source", baseURL: URL(string: "https://source.example")!, usesAuthentication: true)
    try sourcesA.upsert(source, credential: "fixture-source-secret")
    personalA.favorite("alice"); personalA.data.preferences.showChat = false
    personalA.data.oauthSettings = .init(clientID: "public-a", deviceClientID: "public-b", redirect: "https://login.example/callback")
    personalA.recordViewing(WatchSession(login: "alice", seconds: 120))
    await a.sync(); await b.sync()
    #expect(personalB.data.favorites == ["alice"])
    #expect(personalB.data.preferences.showChat == false)
    #expect(personalB.data.oauthSettings == personalA.data.oauthSettings)
    #expect(sourcesB.active?.id == source.id)
    #expect(try sourcesB.credential(for: source.id) == "fixture-source-secret")
    #expect(try sourcesB.client().source.id == source.id)
    #expect(personalB.interests.first?.seconds == 120)
    let sealed = try Data(contentsOf: directory.appendingPathComponent("a/sync.sealed"))
    #expect(!String(decoding: sealed, as: UTF8.self).contains("fixture-source-secret"))
    #expect(!String(decoding: try Data(contentsOf: directory.appendingPathComponent("a/sources.json")), as: UTF8.self).contains("fixture-source-secret"))
    try sourcesA.upsert(source, credential: "rotated-fixture-secret")
    await a.sync(); await b.sync()
    #expect(try sourcesB.credential(for: source.id) == "rotated-fixture-secret")
    let unchangedRevisions = cloudB.values.mapValues(\.revision)
    await b.sync()
    #expect(unchangedRevisions == cloudB.values.mapValues(\.revision))
    await transport.setOnline(false)
    personalA.data.preferences.chatFontSize = 19
    personalB.data.preferences.timestamps = true
    personalA.recordViewing(WatchSession(login: "bob", seconds: 60))
    personalB.recordViewing(WatchSession(login: "alice", seconds: 90))
    personalB.favorite("alice") // Removal must survive an offline peer.
    try sourcesB.remove(source.id)
    await b.sync()
    await transport.setOnline(true)
    await a.sync(); await b.sync(); await a.sync()
    #expect(personalA.data.preferences.chatFontSize == 19)
    #expect(personalB.data.preferences.chatFontSize == 19)
    #expect(personalA.data.preferences.timestamps)
    #expect(personalA.interests.first?.seconds == 210)
    #expect(personalA.interests.first?.visits == 2)
    #expect(personalA.data.favorites.isEmpty)
    #expect(sourcesA.sources.isEmpty)
    #expect(try sourcesA.credential(for: source.id) == nil)
    personalA.clearHistory(); await a.sync(); await b.sync()
    #expect(personalB.interests.isEmpty)
    // Account switching may never upload the previous account's credentials/history.
    await transport.setAccount("different-account")
    await a.sync()
    #expect(cloudA.status.contains("account changed"))
}

@Test @MainActor func syncJournalRestartAndSeedPreservesServerValues() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = FixtureCloud(), secrets = MemorySecrets()
    let file = directory.appendingPathComponent("sync.sealed")
    let first = CloudSyncStore(transport: transport, file: file, secrets: secrets)
    first.put("favorite/alice", payload: Data("true".utf8))
    await transport.setOnline(false); await first.sync()
    let restarted = CloudSyncStore(transport: transport, file: file, secrets: secrets)
    #expect(restarted.values["favorite/alice"]?.payload == Data("true".utf8))
    await transport.setOnline(true); await restarted.sync()
    let newDevice = CloudSyncStore(transport: transport, file: directory.appendingPathComponent("new.sealed"), secrets: MemorySecrets())
    newDevice.put("favorite/alice", payload: nil, seed: true)
    await newDevice.sync()
    #expect(newDevice.values["favorite/alice"]?.payload == Data("true".utf8))
    let tombstone = SyncValue(key: "favorite/alice", payload: nil, modifiedAt: Date().addingTimeInterval(10))
    _ = try await transport.save(tombstone)
    await restarted.sync()
    #expect(restarted.values["favorite/alice"]?.payload == nil)
}

@Test @MainActor func resumePositionsAreSeparateFromInterestAndMultipleVideosSurvive() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let personal = PersonalStore(url: directory.appendingPathComponent("personal.json"))
    personal.watched(.init(login: "alice", title: "One", position: 10000, contentType: "vod", contentID: "1"))
    personal.watched(.init(login: "alice", title: "Two", position: 400, contentType: "vod", contentID: "2"))
    #expect(personal.data.history.count == 2)
    #expect(personal.interests.isEmpty)
    var session = WatchSession(login: "Alice", seconds: 10)
    personal.recordViewing(session); session.seconds = 180; personal.recordViewing(session)
    personal.recordViewing(WatchSession(login: "bob", seconds: 60))
    #expect(personal.interests.first?.login == "alice")
    #expect(personal.interests.first?.visits == 1)
    #expect(personal.interests.first?.seconds == 180)
}

@Test func personalizedStreamsUseAllTrackedLogins() async throws {
    let transport = FixtureTransport([streamPage])
    let api = TwitchAPIClient(clientID: "fixture", token: "fixture", transport: transport)
    let page = try await api.streams(logins: ["alice", "bob"])
    let request = try #require(await transport.requests.first)
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.filter { $0.name == "user_login" }.compactMap(\.value) == ["alice", "bob"])
    #expect(page.data.first?.userLogin == "alice")
}
