import Foundation

/// Key-value persistence. The default is one JSON file in Application Support.
public protocol OrbitStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

/// HTTP transport. Throws on network failure.
public protocol OrbitTransport: Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> Int
    func get(url: URL) async throws -> (Int, Data)
    /// A request whose response body is needed (the signed-in account's decisions).
    func exchange(method: String, url: URL, body: Data?) async throws -> (Int, Data)
}

public extension OrbitTransport {
    /// Custom transports written before `exchange` existed keep working: without a body the account sync is skipped.
    func exchange(method: String, url: URL, body: Data?) async throws -> (Int, Data) { (try await send(method: method, url: url, body: body), Data()) }
}

/// `Application Support/Orbit/orbit.json`, written atomically: the opaque id, choices, cached config and unsent queue.
final class FileStore: OrbitStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: [String: String]

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
        let dir = base.appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("orbit.json")
        cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return cache[key] }

    func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = value
        guard let data = try? JSONEncoder().encode(cache) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// URLSession with an ephemeral configuration: no cookies, no cache, no credential storage. Never logs URLs (they carry
/// the public key).
final class URLSessionTransport: OrbitTransport {
    private let session: URLSession
    private let appId: String

    init(appId: String) {
        self.appId = appId
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "orbit-ios/\(Orbit.version)", "X-Orbit-App": appId, "Accept": "application/json"]
        session = URLSession(configuration: c, delegate: RejectRedirects(), delegateQueue: nil)
    }

    private func run(_ r: URLRequest) async throws -> (Int, Data) {
        guard Orbit.isTLS(r.url) else { throw URLError(.secureConnectionFailed) }
        return try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: r) { data, resp, err in
                if let err { return cont.resume(throwing: err) }
                cont.resume(returning: ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }.resume()
        }
    }

    func send(method: String, url: URL, body: Data?) async throws -> Int {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await run(r).0
    }

    func exchange(method: String, url: URL, body: Data?) async throws -> (Int, Data) {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await run(r)
    }

    func get(url: URL) async throws -> (Int, Data) { try await run(URLRequest(url: url)) }
}
