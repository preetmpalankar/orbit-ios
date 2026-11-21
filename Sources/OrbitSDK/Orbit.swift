import Foundation

/// Orbit SDK by JuriCloud: DPDP Act 2023 consent for iOS apps.
///
/// ```swift
/// Orbit.start(publicKey: "pk_live_xxxxxxxxxxxx")
/// if Orbit.consent.isGranted("analytics") { … }
/// ```
/// Orbit never reads the IDFA and does not link AdSupport or AppTrackingTransparency.
public enum Orbit {
    public static let version = "1.0.1"
    public static let defaultAPI = "https://apidpdp-orbit.juricloud.co/api/v1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: OrbitConsent?
    // Before start (or after a bad key) everything reads as not granted and nothing is sent.
    private static let inert = OrbitConsent(store: MemoryStore(), transport: NoTransport(), apiURL: defaultAPI, key: "")

    /// The consent API. Before `start`, an inert instance where every non-essential purpose is not granted.
    public static var consent: OrbitConsent { lock.lock(); defer { lock.unlock() }; return shared ?? inert }

    /// Idempotent. Loads the notice config and sends queued records in the background; never blocks on the network.
    public static func start(publicKey: String, apiURL: String = defaultAPI, appReport: Bool = false) {
        guard publicKey.range(of: "^pk_live_[0-9A-Za-z]{12}$", options: .regularExpression) != nil else {
            return assertionFailure("Orbit: publicKey must be a pk_live_ key (never a secret key)")
        }
        guard isTLS(URL(string: apiURL)) else { return assertionFailure("Orbit: apiURL must use https") }
        lock.lock()
        if shared != nil { lock.unlock(); return }
        let appId = Bundle.main.bundleIdentifier ?? "unknown"
        let c = OrbitConsent(store: FileStore(), transport: URLSessionTransport(appId: appId), apiURL: apiURL, key: publicKey,
                             deviceLanguage: String((Locale.preferredLanguages.first ?? "en").prefix(2)).lowercased())
        shared = c
        lock.unlock()
        Task.detached(priority: .utility) {
            await c.load()
            if appReport { await c.sendAppReport(.current()) }
        }
    }

    /// Links consent to your own opaque user id (8–128 of A-Z a-z 0-9 _ . : @ -). Never an email or phone number.
    @discardableResult public static func identify(_ userId: String) -> Bool { consent.identify(userId) }
    @discardableResult public static func identify(_ userId: String, subjectProof: String) -> Bool { consent.identify(userId, subjectProof: subjectProof) }
    public static func resetIdentity() { consent.resetIdentity() }

    public static var principalId: String { consent.principalId }

    /// https only; plain http is allowed for localhost during development.
    static func isTLS(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? ""))
    }
}

final class MemoryStore: OrbitStore, @unchecked Sendable {
    private let lock = NSLock()
    private var m: [String: String] = [:]
    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return m[key] }
    func set(_ key: String, _ value: String?) { lock.lock(); m[key] = value; lock.unlock() }
}

struct NoTransport: OrbitTransport {
    func send(method: String, url: URL, body: Data?) async throws -> Int { throw URLError(.notConnectedToInternet) }
    func get(url: URL) async throws -> (Int, Data) { throw URLError(.notConnectedToInternet) }
}
