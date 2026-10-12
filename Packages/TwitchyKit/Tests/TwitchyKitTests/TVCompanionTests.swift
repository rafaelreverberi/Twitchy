import Foundation
import Testing
@testable import TwitchyCore

@Test func companionPresenceExpiresAndRejectsInvalidRecords() throws {
    let now = Date.now
    let presence = TVLivePresence(id: "tv-a", deviceName: "Living Room", login: "alice", name: "Alice", broadcasterID: "123")
    let data = try JSONEncoder().encode(presence)
    let key = TVLivePresence.keyPrefix + presence.id
    let live = SyncValue(key: key, payload: data, modifiedAt: now)
    #expect(TVLivePresence.active(in: [key: live], now: now) == [presence])
    #expect(TVLivePresence.active(in: [key: live], now: now.addingTimeInterval(60)).isEmpty)
    #expect(TVLivePresence.active(in: [key: SyncValue(key: key, payload: nil)], now: now).isEmpty)
    #expect(TVLivePresence.active(in: [key: SyncValue(key: key, payload: Data("broken".utf8))], now: now).isEmpty)
    #expect(TVLivePresence.active(in: ["wrong": SyncValue(key: TVLivePresence.keyPrefix + "other", payload: data, modifiedAt: now)], now: now).isEmpty)
}

@Test @MainActor func companionHeartbeatCrossesDevicesAndStopClearsPresence() async throws {
    let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let transport = FixtureCloud()
    let tv = CloudSyncStore(transport: transport, file: folder.appendingPathComponent("tv"), secrets: MemorySecrets())
    let phone = CloudSyncStore(transport: transport, file: folder.appendingPathComponent("phone"), secrets: MemorySecrets())
    let presence = TVLivePresence(id: "tv", deviceName: "TV", login: "alice", name: "Alice", broadcasterID: "123")
    let payload = try JSONEncoder().encode(presence), key = TVLivePresence.keyPrefix + presence.id
    tv.put(key, payload: payload); await tv.sync(); await phone.sync()
    #expect(TVLivePresence.active(in: phone.values) == [presence])
    let oldRevision = tv.values[key]?.revision
    tv.put(key, payload: payload, refresh: true)
    #expect(tv.values[key]?.revision != oldRevision)
    await tv.sync(); await phone.sync()
    #expect(tv.values[key] == phone.values[key])
    tv.put(key, payload: nil); await tv.sync(); await phone.sync()
    #expect(TVLivePresence.active(in: phone.values).isEmpty)
}
