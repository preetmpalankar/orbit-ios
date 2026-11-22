import Foundation
import CryptoKit
#if canImport(Combine)
import Combine
#endif

/// A listener registration; call `cancel()` to stop receiving changes.
public final class OrbitSubscription: @unchecked Sendable {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel?(); onCancel = nil }
}

/// Consent state for one app install. Mirrors the web SDK: choices are valid only for the notice version they were
/// given for; every record and withdrawal is written to disk first and resent until the server accepts it.
/// Fail safe: without a valid choice every non-essential purpose reads as not granted.
public final class OrbitConsent: @unchecked Sendable {
    private let store: OrbitStore
    private let transport: OrbitTransport
    private let base: String
    private let key: String
    private let deviceLanguage: String
    private let retryBase: Double
    private let retryMax: Double
    private let lock = NSRecursiveLock()
    private var listeners: [UUID: (ConsentSnapshot) -> Void] = [:]
    private var workerRunning = false
    private var wake = false
    private var loaded = false
    private var configAt: TimeInterval?
    private var configRefreshRunning = false
    var stopped = false // tests: end the retry worker

    public private(set) var config: NoticeConfig?
    private var stored: StoredChoice?
    private var subjectProof: String?
    private let scope: String
    private var stateKey: String { scope + K.state + (principalId.hasPrefix("anon_") ? "" : ":" + principalId) }
    /// Opaque id for this install (`anon_<uuid>`), or the id passed to `identify`.
    public private(set) var principalId: String

    #if canImport(Combine)
    private let subject: CurrentValueSubject<ConsentSnapshot, Never>
    /// Current state, then every change.
    public var publisher: AnyPublisher<ConsentSnapshot, Never> { subject.eraseToAnyPublisher() }
    #endif

    init(store: OrbitStore, transport: OrbitTransport, apiURL: String, key: String, deviceLanguage: String = "en", retryBase: Double = 2, retryMax: Double = 300) {
        self.store = store
        self.transport = transport
        self.base = apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL
        self.key = key
        scope = apiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ":" + key + ":"
        self.deviceLanguage = deviceLanguage
        self.retryBase = retryBase
        self.retryMax = retryMax
        config = store.get(scope + K.config).flatMap { try? JSONDecoder().decode(NoticeConfig.self, from: Data($0.utf8)) }
        stored = store.get(scope + K.state).flatMap { try? Self.decoder.decode(StoredChoice.self, from: Data($0.utf8)) }
        subjectProof = store.get(scope + K.proof)
        loaded = config != nil
        if let p = store.get(scope + K.pid) { principalId = p } else {
            principalId = "anon_\(UUID().uuidString.lowercased())"
            store.set(scope + K.pid, principalId)
        }
        #if canImport(Combine)
        subject = CurrentValueSubject(ConsentSnapshot(statuses: [:], needsConsent: false, ready: false, canShowBanner: false))
        subject.value = snapshot()
        #endif
    }

    /// Locking for async code too (NSLock.lock() is unavailable directly in async contexts).
    private func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // MARK: reading

    private func current() -> [String: ConsentStatus]? {
        lock.lock(); defer { lock.unlock() }
        guard let s = stored else { return nil }
        guard let c = config else { return s.choices }
        return s.v >= c.notice.version ? s.choices : nil
    }

    private func essential(_ p: String) -> Bool { config?.purposes.contains { $0.code == p && $0.essential } ?? false }

    public func state(_ purpose: String) -> ConsentStatus {
        sync { effective(purpose, choices: current() ?? [:]) }
    }

    private func effective(_ purpose: String, choices: [String: ConsentStatus]) -> ConsentStatus {
        if essential(purpose) { return .essential }
        let status = choices[purpose] ?? .unknown
        if status == .granted, configAt.map({ ProcessInfo.processInfo.systemUptime - $0 < 60 }) != true {
            return .unknown
        }
        return status
    }

    /// True only for granted or essential purposes. Unknown, denied, withdrawn and "Orbit unreachable" are false.
    public func isGranted(_ purpose: String) -> Bool { [.granted, .essential].contains(state(purpose)) }

    public var canShowBanner: Bool {
        guard let config else { return false }
        return config.banner?.afterLogin != true || !principalId.hasPrefix("anon_")
    }
    public var needsConsent: Bool { canShowBanner && current() == nil }

    /// Language of the notice: the one the person picked, else the device language if offered, else the first.
    public var language: String {
        get {
            guard let langs = config?.languages, let first = langs.first else { return "en" }
            if let s = store.get(scope + K.lang), langs.contains(s) { return s }
            return langs.contains(deviceLanguage) ? deviceLanguage : first
        }
        set { store.set(scope + K.lang, newValue) }
    }

    public func snapshot() -> ConsentSnapshot {
        lock.lock(); defer { lock.unlock() }
        let cur = current() ?? [:]
        var all: [String: ConsentStatus] = [:]
        for p in Set(cur.keys).union((config?.purposes ?? []).map(\.code)) { all[p] = effective(p, choices: cur) }
        return ConsentSnapshot(statuses: all, needsConsent: needsConsent, ready: loaded, canShowBanner: canShowBanner)
    }

    /// Called now with the current state and after every change, on the thread that made the change.
    @discardableResult
    public func onChange(_ listener: @escaping (ConsentSnapshot) -> Void) -> OrbitSubscription {
        let id = UUID()
        lock.lock(); listeners[id] = listener; lock.unlock()
        listener(snapshot())
        return OrbitSubscription { [weak self] in self?.lock.lock(); self?.listeners[id] = nil; self?.lock.unlock() }
    }

    /// Current state, then every change, until the consumer stops iterating.
    public func changes() -> AsyncStream<ConsentSnapshot> {
        AsyncStream { cont in
            let sub = onChange { cont.yield($0) }
            cont.onTermination = { _ in sub.cancel() }
        }
    }

    private func emit() {
        let s = snapshot()
        lock.lock(); let ls = Array(listeners.values); lock.unlock()
        #if canImport(Combine)
        subject.send(s)
        #endif
        ls.forEach { $0(s) }
    }

    // MARK: deciding

    /// Records a full set of choices for the current notice: purposes mapped to true are granted, every other optional
    /// purpose is denied (or withdrawn if it was granted). Returns false until the config has loaded.
    @discardableResult
    public func record(_ choices: [String: Bool]) -> Bool {
        let recorded = sync {
            guard let c = config else { return false }
            let prev = current() ?? [:]
            var next: [String: ConsentStatus] = [:]
            for p in c.optional {
                next[p.code] = choices[p.code] == true ? .granted : prev[p.code] == .granted ? .withdrawn : .denied
            }
            commit(next, changed: next, version: c.notice.latestVersion ?? c.notice.version)
            return true
        }
        if recorded { emit() }
        return recorded
    }

    @discardableResult public func acceptAll() -> Bool { record(Dictionary(uniqueKeysWithValues: (config?.optional ?? []).map { ($0.code, true) })) }
    @discardableResult public func rejectAll() -> Bool { record([:]) }

    /// Withdraws one granted purpose (DPDP s.6(4)); other choices stay. False if it was not granted.
    @discardableResult
    public func withdraw(_ purpose: String) -> Bool {
        let recorded = sync {
            guard let c = config, var cur = current(), cur[purpose] == .granted else { return false }
            cur[purpose] = .withdrawn
            commit(cur, changed: [purpose: .withdrawn], version: c.notice.latestVersion ?? c.notice.version)
            return true
        }
        if recorded { emit() }
        return recorded
    }

    private func commit(_ all: [String: ConsentStatus], changed: [String: ConsentStatus], version: Int) {
        let choice = StoredChoice(v: version, at: Date(), choices: all)
        stored = choice
        store.set(stateKey, (try? Self.encoder.encode(choice)).map { String(decoding: $0, as: UTF8.self) })
        if !changed.isEmpty { enqueue(changed, version: version) }
    }

    /// Changes accounts without transferring the previous person's choices.
    @discardableResult
    public func identify(_ userId: String) -> Bool { identify(userId, subjectProof: nil) }

    @discardableResult
    public func identify(_ userId: String, subjectProof: String?) -> Bool {
        guard !userId.hasPrefix("anon_"), userId.range(of: "^[A-Za-z0-9_.:@-]{8,128}$", options: .regularExpression) != nil else { return false }
        lock.lock()
        if userId == principalId, subjectProof == self.subjectProof { lock.unlock(); return true }
        principalId = userId
        self.subjectProof = subjectProof
        stored = store.get(stateKey).flatMap { try? Self.decoder.decode(StoredChoice.self, from: Data($0.utf8)) }
        lock.unlock()
        emit()
        Task.detached(priority: .utility) { [weak self] in await self?.syncAccount(force: true) }
        return true
    }

    private var syncedAt: TimeInterval = 0

    /// A signed-in person's decisions live with their account, not this device: a decision or withdrawal made on another
    /// device applies here (DPDP s.6(6): processing stops on withdrawal), and an account that already decided is not
    /// asked again. Unsent decisions on this device are newer and win. Anonymous choices stay on their device.
    func syncAccount(force: Bool = false) async {
        let request: (who: String, body: Data)? = sync {
            guard config != nil, !principalId.hasPrefix("anon_"), let proof = subjectProof,
                  force || ProcessInfo.processInfo.systemUptime - syncedAt > 60,
                  !queue().contains(where: { $0.body.principalRef == principalId }),
                  let body = try? JSONEncoder().encode(["principalRef": principalId, "subjectProof": proof]) else { return nil }
            syncedAt = ProcessInfo.processInfo.systemUptime
            return (principalId, body)
        }
        guard let request, let u = url("state"),
              let (code, data) = try? await transport.exchange(method: "POST", url: u, body: request.body), (200..<300).contains(code),
              let account = try? JSONDecoder().decode(AccountState.self, from: data) else { return }
        let changed = sync { () -> Bool in
            guard request.who == principalId, let c = config, !queue().contains(where: { $0.body.principalRef == request.who }) else { return false }
            var decided: [String: ConsentStatus] = [:]
            for p in account.purposes {
                if let s = ConsentStatus(rawValue: p.state), [.granted, .denied, .withdrawn].contains(s) { decided[p.purpose] = s }
            }
            let codes = c.optional.map(\.code)
            let local = stored
            var next: StoredChoice?
            if !codes.isEmpty, codes.allSatisfy({ decided[$0] != nil }) {
                // Every purpose answered under the current notice ("review" grants are not answers).
                next = StoredChoice(v: c.notice.version, at: Date(), choices: Dictionary(uniqueKeysWithValues: codes.map { ($0, decided[$0]!) }))
            } else if let local {
                var choices = local.choices
                for code in codes where choices[code] == .granted { if let d = decided[code], d != .granted { choices[code] = d } }
                if choices != local.choices { next = StoredChoice(v: local.v, at: local.at, choices: choices) }
            }
            guard let next, !(local?.v == next.v && local?.choices == next.choices) else { return false }
            stored = next
            store.set(stateKey, (try? Self.encoder.encode(next)).map { String(decoding: $0, as: UTF8.self) })
            return true
        }
        if changed { emit() }
    }

    public func resetIdentity() {
        let changed = sync {
            guard !principalId.hasPrefix("anon_") else { return false }
            principalId = "anon_\(UUID().uuidString.lowercased())"
            subjectProof = nil
            stored = nil
            store.set(scope + K.pid, principalId)
            store.set(scope + K.proof, nil)
            store.set(scope + K.state, nil)
            if let appId = config?.app?.id { bindAnonymous(appId) }
            return true
        }
        if changed { emit() }
    }

    private func bindAnonymous(_ appId: String) {
        guard principalId.hasPrefix("anon_"), !principalId.hasPrefix("anon_v2_") else { return }
        var rng = SystemRandomNumberGenerator()
        let proof = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
        guard let payload = try? JSONEncoder().encode([appId, proof]) else { return }
        principalId = "anon_v2_" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        subjectProof = proof
        stored = nil
        store.set(scope + K.pid, principalId)
        store.set(scope + K.proof, proof)
        store.set(scope + K.state, nil)
    }

    // MARK: network (never on the caller's thread: always inside a Task)

    private func url(_ path: String) -> URL? {
        var c = URLComponents(string: "\(base)/c/v1/\(path)")
        c?.queryItems = [URLQueryItem(name: "key", value: key)]
        return c?.url
    }

    /// Loads the notice config (keeping the cached copy on failure), then sends anything still queued.
    public func load() async {
        if let u = url("config"), let (code, data) = try? await transport.get(url: u), (200..<300).contains(code),
           let cfg = try? JSONDecoder().decode(NoticeConfig.self, from: data) {
            sync {
                if let appId = cfg.app?.id { bindAnonymous(appId) }
                configAt = ProcessInfo.processInfo.systemUptime
                config = cfg; store.set(scope + K.config, String(decoding: data, as: UTF8.self))
            }
        }
        let startRefresh = sync {
            loaded = true
            if configRefreshRunning { return false }
            configRefreshRunning = true
            return true
        }
        if startRefresh {
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.emit()
                    await self.load()
                }
            }
        }
        emit()
        kick()
        await syncAccount()
    }

    private func queue() -> [QueueItem] {
        store.get(scope + K.queue).flatMap { try? JSONDecoder().decode([QueueItem].self, from: Data($0.utf8)) } ?? []
    }

    private func saveQueue(_ q: [QueueItem]) {
        store.set(scope + K.queue, (try? JSONEncoder().encode(q)).map { String(decoding: $0, as: UTF8.self) })
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return queue().count }

    private func enqueue(_ choices: [String: ConsentStatus], version: Int) {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = QueueItem.Body(principalRef: principalId, language: language, noticeVersion: version,
                                  choices: choices.sorted { $0.key < $1.key }.map { .init(purpose: $0.key, action: $0.value.rawValue) },
                                  decisionId: id, decisionAt: clock.string(from: Date()), subjectProof: subjectProof)
        // shortcut: oldest records are dropped beyond 500 (months offline); raise the cap if that shows up.
        saveQueue(Array((queue() + [QueueItem(id: id, body: body)]).suffix(500))) // on disk before any send
        lock.unlock()
        kick()
    }

    /// One background worker drains the queue, retrying with exponential backoff while Orbit is unreachable.
    private func kick() {
        lock.lock(); defer { lock.unlock() }
        wake = true
        if workerRunning { return }
        workerRunning = true
        Task.detached(priority: .utility) { [weak self] in
            while let self {
                let go = self.sync { () -> Bool in
                    if !self.wake || self.stopped { self.workerRunning = false; return false }
                    self.wake = false
                    return true
                }
                if !go { return }
                var attempt = 0.0
                while !self.stopped, !(await self.flush()) {
                    try? await Task.sleep(nanoseconds: UInt64(min(self.retryMax, self.retryBase * pow(2, attempt)) * 1e9))
                    attempt = min(attempt + 1, 20)
                }
            }
        }
    }

    private enum Outcome { case done, drop, retry }

    private func post(_ path: String, _ body: Data) async -> Outcome {
        guard let u = url(path), let code = try? await transport.send(method: "POST", url: u, body: body) else { return .retry }
        if (200..<300).contains(code) { return .done }
        // 401/403 (key or allowed apps misconfigured) and 408/429 can be fixed server-side: keep and retry.
        if (400..<500).contains(code) && ![401, 403, 408, 429].contains(code) { return .drop }
        return .retry
    }

    /// True when the queue is empty, false when the server could not be reached.
    private func flush() async -> Bool {
        while true {
            let item = sync { queue().first }
            guard let item else { return true }
            guard let data = try? JSONEncoder().encode(item.body) else { return true }
            if await post("consents", data) == .retry { return false }
            sync { saveQueue(queue().filter { $0.id != item.id }) }
        }
    }

    /// Sends the app report once per app version. Never contains personal data.
    public func sendAppReport(_ report: AppReport) async {
        guard store.get(scope + K.reported) != report.versionName, let data = try? JSONEncoder().encode(report) else { return }
        if await post("app-report", data) == .done { store.set(scope + K.reported, report.versionName) }
    }

    enum K {
        static let pid = "orbit_pid", state = "orbit_consent", queue = "orbit_queue", config = "orbit_config"
        static let proof = "orbit_subject_proof"
        static let lang = "orbit_lang", reported = "orbit_app_report_version"
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
