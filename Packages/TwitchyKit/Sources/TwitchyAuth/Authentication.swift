import Foundation
import Observation
import AuthenticationServices
import TwitchyCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct OAuthConfiguration: Sendable {
    public var clientID: String; public var redirectURI: URL; public var deviceClientID: String
    public var callbackURI: URL { URL(string: "twitchy://oauth")! }
    public init(clientID: String, redirectURI: URL, deviceClientID: String = "") { self.clientID = clientID; self.redirectURI = redirectURI; self.deviceClientID = deviceClientID }
}
public struct TokenValidation: Codable, Sendable {
    public var clientId: String; public var login: String?; public var userId: String?; public var scopes: [String]; public var expiresIn: Int
}
public struct AuthSession: Codable, Sendable {
    public var accessToken: String; public var refreshToken: String?; public var clientID: String; public var userID: String; public var login: String; public var scopes: [String]; public var expiresAt: Date
    public var isExpired: Bool { expiresAt <= .now }
}
public struct DeviceCode: Codable, Sendable {
    public var deviceCode: String; public var userCode: String; public var verificationUri: String; public var expiresIn: Int; public var interval: Int
}
public struct OAuthAttempt: Sendable {
    public let state: String
    public let redirect: URL
    public let url: URL
    public init(configuration: OAuthConfiguration, scopes: [String]) throws {
        guard !configuration.clientID.isEmpty, configuration.redirectURI.scheme == "https", configuration.redirectURI.host != nil else { throw ClientError.message("Set your Twitch Client ID and owned HTTPS redirect page in Settings.") }
        state = UUID().uuidString + UUID().uuidString; redirect = configuration.callbackURI
        var c = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")!
        c.queryItems = [ .init(name: "client_id", value: configuration.clientID), .init(name: "redirect_uri", value: configuration.redirectURI.absoluteString), .init(name: "response_type", value: "token"), .init(name: "scope", value: scopes.joined(separator: " ")), .init(name: "state", value: state) ]
        url = c.url!
    }
    public func token(from callback: URL) throws -> String {
        guard callback.scheme == redirect.scheme, callback.host == redirect.host, callback.path == redirect.path else { throw ClientError.invalidURL }
        var c = URLComponents(); c.percentEncodedQuery = callback.fragment ?? URLComponents(url: callback, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        let values = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard values["state"] == state else { throw ClientError.message("The sign-in response could not be verified. Start sign-in again.") }
        guard values["error"] == nil, let token = values["access_token"], !token.isEmpty else { throw ClientError.message("Twitch sign-in was not authorized.") }
        return token
    }
}
@MainActor @Observable public final class TwitchAuthManager: NSObject {
    public private(set) var session: AuthSession?
    public private(set) var deviceCode: DeviceCode?
    public private(set) var status = "Not connected"
    public private(set) var error: String?
    public private(set) var connectionUnavailable = false
    private func noteConnectionError(_ error: Error) {
        if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost].contains(error.code) { connectionUnavailable = true }
    }
    private let secrets: any SecretStore
    private let http: HTTPClient
    private var generation = UUID()
    private var browser: ASWebAuthenticationSession?
    private var validationTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var validationOperation: Task<Void, Error>?
    private var validationID = UUID()
    public var isSigningIn: Bool { status == "Signing in" || deviceCode != nil }
    public init(secrets: any SecretStore = KeychainStore(service: "com.rafaelreverberi.Twitchy.twitch"), transport: any HTTPTransport = NetworkTransport()) { self.secrets = secrets; http = HTTPClient(transport: transport); super.init() }
    public func restore(validateOnline: Bool = true) async {
        connectionUnavailable = false
        let current = generation
        do {
            if let bytes = try secrets.read("session") {
                session = try JSONDecoder().decode(AuthSession.self, from: bytes)
                if validateOnline { try await validate() }
                else { status = "Signed in" }
            }
        } catch { if generation == current { self.error = error.localizedDescription; noteConnectionError(error); status = "Sign-in needs attention" } }
    }
    public func validate() async throws {
        connectionUnavailable = false
        if let operation = validationOperation { return try await operation.value }
        let id = UUID(); validationID = id
        let operation = Task { try await self.validateStoredSession() }
        validationOperation = operation
        defer { if validationID == id { validationOperation = nil } }
        do { try await operation.value }
        catch {
            if validationID == id, !(error is CancellationError) {
                self.error = error.localizedDescription
                noteConnectionError(error)
                status = session == nil ? "Sign in again" : "Connection needs attention"
            }
            throw error
        }
    }
    private func validateStoredSession(allowRefresh: Bool = true) async throws {
        guard let stored = session else { return }
        let current = generation
        var r = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!); r.setValue("OAuth \(stored.accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let v = try await http.decode(TokenValidation.self, request: r)
            guard v.clientId == stored.clientID, v.userId == stored.userID, v.expiresIn > 0 else { throw ClientError.unauthorized }
            guard generation == current, session?.accessToken == stored.accessToken else { throw CancellationError() }
            var updated = stored; updated.expiresAt = Date().addingTimeInterval(Double(v.expiresIn)); updated.scopes = v.scopes
            try save(updated); status = "Connected"; error = nil; if validationTask == nil { startValidation() }
        } catch ClientError.unauthorized {
            guard generation == current, session?.accessToken == stored.accessToken else { throw CancellationError() }
            if stored.refreshToken != nil {
                guard allowRefresh else { throw ClientError.unauthorized }
                try await refresh(stored)
            } else { try secrets.delete("session"); session = nil; status = "Sign in again"; throw ClientError.message("Your previous sign-in could not renew itself. Sign in once to enable automatic renewal.") }
        }
    }
    private func refresh(_ stored: AuthSession) async throws {
        let current = generation
        guard let refresh = stored.refreshToken else { throw ClientError.unauthorized }
        do {
            let token = try await tokenResponse(["client_id": stored.clientID, "grant_type": "refresh_token", "refresh_token": refresh])
            guard generation == current, session?.accessToken == stored.accessToken else { throw CancellationError() }
            // Public refresh tokens are single-use. Persist the replacement before any more network calls.
            var rotated = stored
            rotated.accessToken = token.accessToken; rotated.refreshToken = token.refreshToken ?? refresh
            rotated.expiresAt = .distantPast // It must be validated before Helix can use it.
            try save(rotated)
            try await validateStoredSession(allowRefresh: false)
        } catch {
            if generation == current, case OAuthFailure.invalidRefresh = error {
                try secrets.delete("session"); session = nil; status = "Sign in again"
            }
            throw error
        }
    }
    private func save(_ value: AuthSession) throws { try secrets.write(JSONEncoder().encode(value), key: "session"); session = value }
    private func establish(access: String, refresh: String?, clientID: String, generation current: UUID) async throws {
        var r = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!); r.setValue("OAuth \(access)", forHTTPHeaderField: "Authorization")
        let v = try await http.decode(TokenValidation.self, request: r)
        guard v.clientId == clientID, let userID = v.userId, let login = v.login, v.expiresIn > 0 else { throw ClientError.unauthorized }
        guard generation == current else { throw CancellationError() }
        try save(.init(accessToken: access, refreshToken: refresh, clientID: clientID, userID: userID, login: login, scopes: v.scopes, expiresAt: Date().addingTimeInterval(Double(v.expiresIn))))
        status = "Connected"; error = nil; if validationTask == nil { startValidation() }
    }
    private func startValidation() {
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3500)); guard !Task.isCancelled else { return }; try await self?.validate() }
                catch is CancellationError { return }
                catch { self?.error = error.localizedDescription; self?.status = "Connection needs attention" }
            }
        }
    }
    public func login(configuration: OAuthConfiguration, chat: Bool = false) async {
        await startDeviceLogin(clientID: configuration.deviceClientID, chat: chat)
    }
    public func loginWithBrowser(configuration: OAuthConfiguration, chat: Bool = false) async {
        #if !os(tvOS)
        let current = UUID(); generation = current
        browser?.cancel(); deviceTask?.cancel(); deviceTask = nil; deviceCode = nil
        cancelValidationOperation()
        do {
            let attempt = try OAuthAttempt(configuration: configuration, scopes: ["user:read:follows"] + (chat ? ["user:read:chat", "user:write:chat"] : []))
            status = "Signing in"
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                browser = ASWebAuthenticationSession(url: attempt.url, callbackURLScheme: configuration.callbackURI.scheme) { url, error in
                    if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? ClientError.unauthorized) }
                }
                browser?.presentationContextProvider = self; browser?.prefersEphemeralWebBrowserSession = false
                if browser?.start() != true { continuation.resume(throwing: ClientError.message("Could not open the system sign-in window.")) }
            }
            try await establish(access: attempt.token(from: callback), refresh: nil, clientID: configuration.clientID, generation: current); browser = nil
        } catch { if generation == current { self.error = error.localizedDescription; status = session == nil ? "Not connected" : "Connected" } }
        #else
        await startDeviceLogin(clientID: configuration.deviceClientID, chat: chat)
        #endif
    }
    private struct TokenResponse: Codable, Sendable { var accessToken: String; var refreshToken: String? }
    private func formRequest(_ path: String, _ values: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/\(path)")!); r.httpMethod = "POST"
        // Percent-encode '+' and '&' too; query encoding alone is insufficient for form bodies.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        r.httpBody = values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").data(using: .utf8)
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); return r
    }
    private enum OAuthFailure: LocalizedError {
        case invalidRefresh, configuration, rejected
        var errorDescription: String? {
            switch self {
            case .invalidRefresh: "Twitch authorization expired or was revoked. Sign in again."
            case .configuration: "Automatic sign-in renewal requires a Public Twitch application. Check Client Type in the Twitch Developer Console and the Client ID in Advanced settings."
            case .rejected: "Twitch could not authorize this request. Check the application configuration and try signing in again."
            }
        }
    }
    private struct Failure: Decodable { var message: String?; var error: String? }
    private func oauthFailure(_ result: HTTPResult) -> any Error {
        let failure = try? JSONDecoder().decode(Failure.self, from: result.data)
        let reason = (failure?.message ?? failure?.error ?? "").lowercased()
        if reason.contains("invalid refresh token") || reason == "invalid_grant" { return OAuthFailure.invalidRefresh }
        if reason.contains("client") { return OAuthFailure.configuration }
        return result.status == 400 || result.status == 401 ? OAuthFailure.rejected : ClientError.server(result.status)
    }
    private func tokenResponse(_ values: [String: String]) async throws -> TokenResponse {
        let result = try await http.transport.send(formRequest("token", values))
        guard result.status == 200 else { throw oauthFailure(result) }
        return try JSONCoding.decoder().decode(TokenResponse.self, from: result.data)
    }
    private func cancelValidationOperation() {
        validationID = UUID(); validationOperation?.cancel(); validationOperation = nil
        validationTask?.cancel(); validationTask = nil
    }
    public func cancelLogin() {
        generation = UUID(); deviceTask?.cancel(); deviceTask = nil; deviceCode = nil
        #if !os(tvOS)
        browser?.cancel(); browser = nil
        #endif
        cancelValidationOperation()
        status = session == nil ? "Not connected" : "Connection needs attention"; error = nil
    }
    public func startDeviceLogin(clientID: String, chat: Bool = false) async {
        guard !clientID.isEmpty else { error = "Set a public Device Flow Client ID in Settings."; return }
        deviceTask?.cancel(); cancelValidationOperation(); error = nil; status = "Signing in"
        #if !os(tvOS)
        browser?.cancel()
        #endif
        let current = UUID(); generation = current
        do {
            let scopes = (["user:read:follows"] + (chat ? ["user:read:chat", "user:write:chat"] : [])).joined(separator: " ")
            let response = try await http.transport.send(formRequest("device", ["client_id": clientID, "scopes": scopes]))
            guard response.status == 200 else { throw oauthFailure(response) }
            let code = try JSONCoding.decoder().decode(DeviceCode.self, from: response.data); guard generation == current else { return }; deviceCode = code; status = "Waiting for authorization"
            let deadline = Date().addingTimeInterval(Double(code.expiresIn))
            deviceTask = Task { [weak self] in
                guard let self else { return }
                var interval = max(1, code.interval)
                do {
                    while Date() < deadline {
                        try await Task.sleep(for: .seconds(interval)); try Task.checkCancellation()
                        let result = try await http.transport.send(formRequest("token", ["client_id": clientID, "scopes": scopes, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]))
                        if result.status == 200 {
                            let token = try JSONCoding.decoder().decode(TokenResponse.self, from: result.data)
                            try await establish(access: token.accessToken, refresh: token.refreshToken, clientID: clientID, generation: current); deviceCode = nil; return
                        }
                        let f = try JSONDecoder().decode(Failure.self, from: result.data); let reason = f.message ?? f.error ?? ""
                        if reason == "authorization_pending" { continue }
                        if reason == "slow_down" { interval += 5; continue }
                        throw oauthFailure(result)
                    }
                    throw ClientError.message("The device code expired. Start sign-in again.")
                } catch is CancellationError { }
                catch { if generation == current { self.error = error.localizedDescription; status = "Not connected"; deviceCode = nil } }
            }
        } catch { if generation == current { self.error = error.localizedDescription; status = session == nil ? "Not connected" : "Connection needs attention" } }
    }
    public func logout() async {
        connectionUnavailable = false
        generation = UUID(); cancelValidationOperation()
        validationTask?.cancel(); validationTask = nil; deviceTask?.cancel(); deviceTask = nil; deviceCode = nil
        #if !os(tvOS)
        browser?.cancel()
        #endif
        let old = session
        do { try secrets.delete("session"); session = nil; status = "Not connected"; error = nil }
        catch { self.error = error.localizedDescription; return }
        if let old { do { _ = try await http.response(formRequest("revoke", ["client_id": old.clientID, "token": old.accessToken])) } catch { self.error = "Signed out locally. Twitch revocation failed; revoke Twitchy in your Twitch Connections settings." } }
    }
}
#if !os(tvOS)
extension TwitchAuthManager: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? UIWindow()
        #endif
    }
}
#endif
