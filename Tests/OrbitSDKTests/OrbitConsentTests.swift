import Foundation
import Testing
@testable import OrbitSDK

/// Fake Orbit server. `down` = connection refused; `postCode` = status for POSTs.
final class FakeTransport: OrbitTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _down = false, _postCode = 201, _version = 1
    private(set) var posts: [(URL, [String: Any])] = []
    private(set) var onMainThread = false
    private(set) var calls = 0
    var down: Bool { get { lock.lock(); defer { lock.unlock() }; return _down } set { lock.lock(); _down = newValue; lock.unlock() } }
    var postCode: Int { get { lock.lock(); defer { lock.unlock() }; return _postCode } set { lock.lock(); _postCode = newValue; lock.unlock() } }
    var version: Int { get { lock.lock(); defer { lock.unlock() }; return _version } set { lock.lock(); _version = newValue; lock.unlock() } }
    var postCount: Int { lock.lock(); defer { lock.unlock() }; return posts.count }

    private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private func touch() throws {
        let main = Thread.isMainThread
        let d = sync { calls += 1; if main { onMainThread = true }; return _down }
        if d { throw URLError(.cannotConnectToHost) }
    }
    func get(url: URL) async throws -> (Int, Data) {
        try touch()
        return (200, Data(configJSON(version).utf8))
    }
    func send(method: String, url: URL, body: Data?) async throws -> Int {
        try touch()
        let obj = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
        return sync { posts.append((url, obj)); return _postCode }
    }
}

func configJSON(_ v: Int) -> String { """
{"app":{"name":"Shop"},"org":{"name":"Acme Retail","contactEmail":null,"privacyCentreUrl":"https://orbit.example/p/acme"},
 "notice":{"documentId":"d1","version":\(v),"url":"https://orbit.example/n/acme/d1","summary":{"en":"We use your data.","hi":"हम डेटा का उपयोग करते हैं।"}},
 "languages":["en","hi"],"ui":{"en":{"acceptAll":"Accept all"},"hi":{"acceptAll":"सभी स्वीकार करें"}},
 "purposes":[{"code":"service","title":"Service","description":"Run the app","essential":true,"translations":{}},
             {"code":"analytics","title":"Analytics","description":"Usage stats","essential":false,"translations":{"hi":{"title":"विश्लेषण","description":"x"}}},
             {"code":"marketing","title":"Marketing","description":"Offers","essential":false,"translations":{}}]}
""" }

// Swift Testing (ships with the Command Line Tools and Xcode 16+); XCTest needs a full Xcode install.
@Suite final class OrbitConsentTests {
    private var engines: [OrbitConsent] = []
    deinit { engines.forEach { $0.stopped = true } }

    private func make(_ store: OrbitStore, _ t: OrbitTransport) -> OrbitConsent {
        let c = OrbitConsent(store: store, transport: t, apiURL: "https://api.test/api/v1", key: "pk_live_abcdefABCDEF", deviceLanguage: "hi", retryBase: 0.01, retryMax: 0.05)
        engines.append(c)
        return c
    }

    private func wait(_ cond: @escaping () -> Bool, timeout: Double = 3) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { Issue.record("timed out"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func failSafeWhenOrbitIsDown() async {
        let t = FakeTransport(); t.down = true
        let c = make(MemoryStore(), t)
        await c.load()
        #expect(c.snapshot().ready)
        #expect(!(c.isGranted("analytics")))
        #expect(!(c.needsConsent))
        #expect(!(c.record(["analytics": true])))
        #expect(c.state("analytics") == .unknown)
    }

    @Test func inertBeforeStart() {
        #expect(!(Orbit.consent.isGranted("analytics")))
        #expect(!(Orbit.consent.acceptAll()))
    }

    @Test func acceptRejectWithdraw() async throws {
        let t = FakeTransport()
        let c = make(MemoryStore(), t)
        await c.load()
        #expect(c.needsConsent)
        #expect(c.language == "hi")
        #expect(c.state("service") == .essential)
        #expect(!(c.isGranted("analytics")))

        c.acceptAll()
        #expect(c.isGranted("analytics") && c.isGranted("marketing"))
        #expect(!(c.needsConsent))
        c.rejectAll()
        #expect(c.state("analytics") == .withdrawn)
        c.record(["analytics": true])
        #expect(c.state("marketing") == .denied)
        #expect(c.withdraw("analytics"))
        #expect(!(c.withdraw("marketing")))

        try await wait { t.postCount == 4 && c.pendingCount == 0 }
        let (url, first) = t.posts[0]
        #expect(url.absoluteString.hasPrefix("https://api.test/api/v1/c/v1/consents?key=pk_live_"))
        #expect(first["principalRef"] as? String == c.principalId)
        #expect(c.principalId.hasPrefix("anon_"))
        #expect(first["noticeVersion"] as? Int == 1)
        #expect((first["choices"] as? [Any])?.count == 2) // essential purposes never sent as consent
        #expect(((t.posts[3].1["choices"] as? [[String: String]])?.first)?["action"] == "withdrawn")
        #expect(!(t.onMainThread))
    }

    @Test func reConsentOnNoticeVersionBump() async throws {
        let store = MemoryStore(), t = FakeTransport()
        let a = make(store, t)
        await a.load(); a.acceptAll()
        a.stopped = true
        t.version = 2
        let c = make(store, t)
        #expect(!c.isGranted("analytics")) // relaunch requires a config refresh
        await c.load()
        #expect(c.needsConsent)
        #expect(!(c.isGranted("analytics")))
        c.acceptAll()
        try await wait { t.posts.last.map { $0.1["noticeVersion"] as? Int == 2 } ?? false }
    }

    @Test func queuePersistsToDiskAndRetries() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let t = FakeTransport()
        let a = make(FileStore(directory: dir), t)
        await a.load()
        t.down = true
        a.acceptAll()
        #expect(a.isGranted("analytics"))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(a.pendingCount == 1)
        #expect(t.calls > 3) // retried with backoff
        a.stopped = true

        // Relaunch: a new store instance reads the same file.
        let b = make(FileStore(directory: dir), t)
        #expect(b.pendingCount == 1)
        #expect(!b.isGranted("analytics"))
        t.down = false
        await b.load()
        try await wait { b.pendingCount == 0 }
        #expect(t.postCount == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Orbit/orbit.json").path))
    }

    @Test func permanentRejectionDropsAuthErrorsRetry() async throws {
        let t = FakeTransport()
        let c = make(MemoryStore(), t)
        await c.load()
        t.postCode = 403
        c.acceptAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(c.pendingCount == 1)
        t.postCode = 400
        try await wait { c.pendingCount == 0 }
    }

    @Test func identifyAndStream() async throws {
        let t = FakeTransport()
        let c = make(MemoryStore(), t)
        await c.load()
        var seen: [Bool] = []
        let stream = c.changes()
        let task = Task { for await s in stream { seen.append(s.isGranted("analytics")); if seen.count == 2 { break } } }
        try await Task.sleep(nanoseconds: 20_000_000)
        c.acceptAll()
        await task.value
        #expect(seen == [false, true])

        try await wait { t.postCount == 1 }
        #expect(!(c.identify("a@b")))
        #expect(!(c.identify("has space in it")))
        #expect(c.identify("user_8f2a91c4"))
        #expect(c.state("analytics") == .unknown)
        #expect(t.postCount == 1)
        c.acceptAll()
        try await wait { t.postCount == 2 }
        #expect(t.posts[1].1["principalRef"] as? String == "user_8f2a91c4")
    }

    @Test func appReportOncePerVersion() async {
        let t = FakeTransport()
        let c = make(MemoryStore(), t)
        let sdks = AppReport.detect { $0 == "AppsFlyerLib" || $0 == "CleverTap" }
        #expect(sdks == ["com.clevertap", "com.appsflyer"])
        let r = AppReport(package: "com.acme.shop", versionName: "4.2.0", sdks: sdks, permissions: ["NSCameraUsageDescription"])
        await c.sendAppReport(r); await c.sendAppReport(r)
        #expect(t.postCount == 1)
        #expect(t.posts[0].0.absoluteString.contains("/c/v1/app-report?key="))
        #expect(Set(t.posts[0].1.keys) == ["platform", "package", "versionName", "sdks", "permissions"])
        await c.sendAppReport(AppReport(package: "com.acme.shop", versionName: "4.3.0", sdks: [], permissions: []))
        #expect(t.postCount == 2)
    }

    @Test func tlsRule() {
        #expect(Orbit.isTLS(URL(string: "https://apidpdp-orbit.juricloud.co")))
        #expect(Orbit.isTLS(URL(string: "http://localhost:3000")))
        #expect(!(Orbit.isTLS(URL(string: "http://api.example.com"))))
    }
}
