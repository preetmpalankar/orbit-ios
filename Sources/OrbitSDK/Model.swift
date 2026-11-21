import Foundation

public enum ConsentStatus: String, Codable, Sendable {
    case granted, denied, withdrawn, essential, unknown
}

/// The consent state at one moment, delivered to listeners, the Combine publisher and the async stream.
public struct ConsentSnapshot: Equatable, Sendable {
    public let statuses: [String: ConsentStatus]
    /// True when the notice must be shown: no choice yet, or the notice version changed since the last choice.
    public let needsConsent: Bool
    /// True once the notice config is loaded (from the server or the last cached copy), or loading has failed.
    public let ready: Bool
    public let canShowBanner: Bool

    public func status(_ purpose: String) -> ConsentStatus { statuses[purpose] ?? .unknown }
    public func isGranted(_ purpose: String) -> Bool { [.granted, .essential].contains(status(purpose)) }
}

/// What the banner needs, from `GET /c/v1/config` (same payload as the web SDK).
public struct NoticeConfig: Codable, Sendable {
    public struct Org: Codable, Sendable { public let name: String; public let privacyCentreUrl: String? }
    public struct App: Codable, Sendable { public let id: String? }
    public struct Notice: Codable, Sendable { public let version: Int; public let latestVersion: Int?; public let url: String?; public let summary: [String: String] }
    public struct Text: Codable, Sendable { public let title: String; public let description: String }
    public struct Purpose: Codable, Sendable {
        public let code: String
        public let title: String
        public let description: String
        public let essential: Bool
        public let translations: [String: Text]?
        public func title(_ lang: String) -> String { translations?[lang]?.title ?? title }
        public func description(_ lang: String) -> String { translations?[lang]?.description ?? description }
    }

    public let org: Org
    public let app: App?
    public let notice: Notice
    public let languages: [String]
    public let ui: [String: [String: String]]?
    public struct Banner: Codable, Sendable { public let afterLogin: Bool? }
    public let banner: Banner?
    public let purposes: [Purpose]

    public var optional: [Purpose] { purposes.filter { !$0.essential } }
    public func summary(_ lang: String) -> String { notice.summary[lang] ?? notice.summary["en"] ?? notice.summary.values.first ?? "" }
    public func label(_ lang: String, _ key: String) -> String { ui?[lang]?[key] ?? ui?["en"]?[key] ?? NoticeConfig.en[key] ?? key }
    public var noticeURL: URL? { NoticeConfig.safe(notice.url) }
    public var privacyCentreURL: URL? { NoticeConfig.safe(org.privacyCentreUrl) }

    static func safe(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), ["https", "http"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return u
    }

    static let en = [
        "acceptAll": "Accept all", "rejectAll": "Reject all", "choose": "Choose purposes", "save": "Save choices",
        "alwaysOn": "Always on", "readNotice": "Read the full notice", "privacyCentre": "Privacy centre",
        "close": "Close", "privacyChoices": "Privacy choices", "language": "Language",
    ]
    static let languageNames = [
        "en": "English", "hi": "हिन्दी", "kn": "ಕನ್ನಡ", "ta": "தமிழ்", "te": "తెలుగు", "mr": "मराठी", "bn": "বাংলা",
        "gu": "ગુજરાતી", "ml": "മലയാളം", "pa": "ਪੰਜਾਬੀ", "or": "ଓଡ଼ିଆ", "as": "অসমীয়া", "ur": "اردو",
    ]
}

struct StoredChoice: Codable {
    let v: Int
    let at: Date
    let choices: [String: ConsentStatus]
}

struct QueueItem: Codable {
    struct Choice: Codable { let purpose: String; let action: String }
    struct Body: Codable {
        let principalRef: String; let language: String; let noticeVersion: Int; let choices: [Choice]
        let decisionId: String?; let decisionAt: String?; let subjectProof: String?
    }
    let id: String
    let body: Body
}
