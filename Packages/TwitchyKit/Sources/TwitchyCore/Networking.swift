import Foundation

public enum ClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL, insecureURL, unauthorized, missingScope, incompatibleAPI, unsupported, noSource
    case rateLimited, server(Int), invalidResponse, message(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid server URL without credentials, query, or fragment."
        case .insecureURL: "Use HTTPS. Local HTTP must be explicitly enabled for a private development server."
        case .unauthorized: "Authentication expired or was rejected. Reconnect your account or check source credentials."
        case .missingScope: "This action needs additional Twitch permissions. Reconnect with the requested permissions."
        case .incompatibleAPI: "This source does not support API v1."
        case .unsupported: "This source does not support this feature."
        case .noSource: "Add and select a streaming source in Profile → Settings → Sources."
        case .rateLimited: "Too many requests. Please wait before trying again."
        case .server(let code): "The service returned an error (\(code)). Try again shortly."
        case .invalidResponse: "The service returned an unexpected response."
        case .message(let message): message
        }
    }
}
public struct HTTPResult: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public init(data: Data, status: Int, headers: [String: String] = [:]) { self.data = data; self.status = status; self.headers = headers }
}
public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPResult }
// Never forward Authorization through redirects, even to another host controlled by a source.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class NetworkTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return HTTPResult(data: data, status: response.statusCode, headers: headers)
    }
}
public enum JSONCoding {
    public static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; d.dateDecodingStrategy = .iso8601; return d }
    public static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.dateEncodingStrategy = .iso8601; return e }
}
public struct HTTPClient: Sendable {
    public let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    public func exchange(_ request: URLRequest) async throws -> HTTPResult {
        for attempt in 0...2 {
            try Task.checkCancellation()
            let result = try await transport.send(request)
            if (result.status == 429 || result.status >= 500), request.httpMethod == "GET", attempt < 2 {
                let reset = result.headers["ratelimit-reset"].flatMap(Double.init).map { max(0, $0 - Date().timeIntervalSince1970) }
                let suggested = result.headers["retry-after"].flatMap(Double.init) ?? reset ?? pow(2, Double(attempt))
                // Do not shorten a server's rate-limit window just to fit our retry budget.
                guard suggested <= 30 else { return result }
                let delay = max(1, suggested)
                try await Task.sleep(for: .seconds(delay)); continue
            }
            return result
        }
        throw ClientError.invalidResponse
    }
    public func response(_ request: URLRequest) async throws -> HTTPResult {
        let result = try await exchange(request)
        switch result.status {
        case 200..<300: return result
        case 401: throw ClientError.unauthorized
        case 403: throw ClientError.missingScope
        case 429: throw ClientError.rateLimited
        default: throw ClientError.server(result.status)
        }
    }
    public func decode<T: Decodable & Sendable>(_ type: T.Type, request: URLRequest) async throws -> T {
        try JSONCoding.decoder().decode(type, from: await response(request).data)
    }
}
