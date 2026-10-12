import Foundation
import TwitchyCore

/// The Twitch OAuth session and downloaded media deliberately never enter this adapter.
@MainActor public final class AppDataSync {
    public let cloud: CloudSyncStore
    private let personal: PersonalStore
    private let sources: StreamingSourceManager
    private var sourceSnapshot: [String: Data] = [:]
    private var selectedSnapshot: UUID?
    private var cacheApplied = false
    private struct SourceValue: Codable { var source: StreamingSource; var credential: String? }
    public init(personal: PersonalStore, sources: StreamingSourceManager, cloud: CloudSyncStore) {
        self.personal = personal; self.sources = sources; self.cloud = cloud
    }
    public func start() throws {
        cloud.onRemoteChange = { [weak self] values in try self?.receive(values) }
        personal.onChange = { [weak self] old, new in self?.publishPersonal(old: old, new: new) }
        sources.onChange = { [weak self] in
            do { try self?.publishSources() }
            catch { self?.cloud.reportLocalFailure("Source credentials are unavailable on this device. Unlock the Keychain and sync again.") }
        }
        try cloud.applyCached()
        publishPersonal(old: nil, new: personal.data, seed: true)
        try publishSources(seed: true)
        cacheApplied = true
    }
    public func sync() async {
        if !cacheApplied {
            do { try start() } catch { cloud.reportLocalFailure("Local sync data or source credentials could not be loaded. Unlock the Keychain and sync again."); return }
        }
        do { try publishSources() } catch { cloud.reportLocalFailure("Source credentials are unavailable on this device. Unlock the Keychain and sync again."); return }
        await cloud.sync()
    }
    private func publish(_ key: String, _ data: Data?, seed: Bool) { cloud.put(key, payload: data, seed: seed) }
    private func fields<T: Encodable>(_ value: T) -> [String: Data] {
        guard let encoded = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return [:] }
        return object.compactMapValues { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
    }
    private func publishPersonal(old: PersonalData?, new: PersonalData, seed: Bool = false) {
        let before = old.map { fields($0.preferences) } ?? [:]
        for (field, data) in fields(new.preferences) where before[field] != data { publish("preference/\(field)", data, seed: seed) }
        if old?.onboardingComplete != new.onboardingComplete { publish("onboarding", try? JSONEncoder().encode(new.onboardingComplete), seed: seed) }
        let favorites = Set(new.favorites), previous = Set(old?.favorites ?? [])
        for login in favorites.subtracting(previous) { publish("favorite/\(login)", try? JSONEncoder().encode(true), seed: seed) }
        for login in previous.subtracting(favorites) { publish("favorite/\(login)", nil, seed: seed) }
        let history = Dictionary(uniqueKeysWithValues: new.history.map { ($0.id, $0) })
        let oldHistory = Dictionary(uniqueKeysWithValues: (old?.history ?? []).map { ($0.id, $0) })
        for (id, entry) in history where oldHistory[id] != entry { publish("history/\(id)", try? JSONEncoder().encode(entry), seed: seed) }
        for id in oldHistory.keys where history[id] == nil { publish("history/\(id)", nil, seed: seed) }
        let sessions = Dictionary(uniqueKeysWithValues: (new.watchSessions ?? []).map { ($0.id, $0) })
        let oldSessions = Dictionary(uniqueKeysWithValues: (old?.watchSessions ?? []).map { ($0.id, $0) })
        for (id, session) in sessions where oldSessions[id] != session { publish("viewing/\(id)", try? JSONEncoder().encode(session), seed: seed) }
        for id in oldSessions.keys where sessions[id] == nil { publish("viewing/\(id)", nil, seed: seed) }
        if old?.historyClearedAt != new.historyClearedAt { publish("historyClearedAt", try? JSONEncoder().encode(new.historyClearedAt), seed: seed) }
        if old?.oauthSettings != new.oauthSettings { publish("oauthSettings", try? JSONEncoder().encode(new.oauthSettings), seed: seed) }
        if old?.recentSearches != new.recentSearches { publish("searches", try? JSONEncoder().encode(new.recentSearches), seed: seed) }
    }
    private func publishSources(seed: Bool = false) throws {
        var snapshot: [String: Data] = [:]
        for var source in sources.sources {
            // Connectivity and capabilities are device-specific; sync only portable configuration.
            source.capabilities = nil; source.serverVersion = nil; source.lastSuccessfulCheck = nil; source.connectionStatus = "Not tested"
            let value = SourceValue(source: source, credential: try sources.credential(for: source.id))
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(value), key = "source/\(source.id)"
            snapshot[key] = data
            if sourceSnapshot[key] != data { publish(key, data, seed: seed) }
        }
        for key in sourceSnapshot.keys where snapshot[key] == nil { publish(key, nil, seed: seed) }
        if seed || selectedSnapshot != sources.activeID { publish("activeSource", try JSONEncoder().encode(sources.activeID), seed: seed) }
        sourceSnapshot = snapshot; selectedSnapshot = sources.activeID
    }
    private func receive(_ values: [SyncValue]) throws {
        for value in values.sorted(by: { $0.key < $1.key }) {
            if value.key.hasPrefix(TVLivePresence.keyPrefix) { continue }
            let parts = value.key.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.first == "source", parts.count == 2, let id = UUID(uuidString: parts[1]) {
                let decoded = try value.payload.map { try JSONDecoder().decode(SourceValue.self, from: $0) }
                if let decoded, decoded.source.id != id { throw ClientError.message("Invalid synced source identifier.") }
                try sources.applySynced(source: decoded?.source, id: id, credential: decoded?.credential)
                // Do not turn incoming changes into fresh local edits.
                if let decoded {
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    sourceSnapshot[value.key] = try encoder.encode(decoded)
                } else { sourceSnapshot.removeValue(forKey: value.key) }
                continue
            }
            if value.key == "activeSource" { continue } // Apply selection after all source records.
            try personal.applySynced { data in
                switch parts.first {
                case "preference" where parts.count == 2:
                    guard let payload = value.payload else { return }
                    var preferences = try JSONSerialization.jsonObject(with: JSONEncoder().encode(data.preferences)) as! [String: Any]
                    preferences[parts[1]] = try JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)
                    data.preferences = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: preferences))
                case "favorite" where parts.count == 2:
                    data.favorites.removeAll { $0 == parts[1] }
                    if value.payload != nil { data.favorites.append(parts[1]); data.favorites.sort() }
                case "history" where parts.count == 2:
                    data.history.removeAll { $0.id == parts[1] }
                    if let payload = value.payload {
                        let entry = try JSONDecoder().decode(WatchEntry.self, from: payload)
                        if entry.watchedAt > (data.historyClearedAt ?? .distantPast) { data.history.append(entry) }
                    }
                    data.history = Array(data.history.sorted { $0.watchedAt > $1.watchedAt }.prefix(100))
                case "viewing" where parts.count == 2:
                    var sessions = data.watchSessions ?? []; sessions.removeAll { $0.id.uuidString == parts[1] }
                    if let payload = value.payload {
                        let session = try JSONDecoder().decode(WatchSession.self, from: payload)
                        if session.watchedAt > (data.historyClearedAt ?? .distantPast), session.seconds.isFinite, session.seconds >= 0 { sessions.append(session) }
                    }
                    data.watchSessions = Array(sessions.sorted { $0.watchedAt > $1.watchedAt }.prefix(2000))
                case "historyClearedAt":
                    if let payload = value.payload, let cutoff = try JSONDecoder().decode(Date?.self, from: payload) {
                        data.historyClearedAt = max(cutoff, data.historyClearedAt ?? .distantPast)
                        data.history.removeAll { $0.watchedAt <= data.historyClearedAt! }
                        data.watchSessions = (data.watchSessions ?? []).filter { $0.watchedAt > data.historyClearedAt! }
                    }
                case "oauthSettings": if let payload = value.payload { data.oauthSettings = try JSONDecoder().decode(OAuthAppSettings?.self, from: payload) }
                case "searches": if let payload = value.payload { data.recentSearches = try JSONDecoder().decode([String].self, from: payload) }
                case "onboarding": if let payload = value.payload { data.onboardingComplete = try JSONDecoder().decode(Bool.self, from: payload) }
                default: break
                }
            }
        }
        if let selection = values.first(where: { $0.key == "activeSource" }) ?? cloud.values["activeSource"], let payload = selection.payload {
            let id = try JSONDecoder().decode(UUID?.self, from: payload)
            try sources.applySyncedSelection(id); selectedSnapshot = sources.activeID
        }
    }
}
