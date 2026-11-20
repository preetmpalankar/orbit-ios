import Foundation

/// What the optional app report sends: bundle id and version, which known third-party SDKs are linked in (named by the
/// package prefixes of Orbit's tracker list, so the server matches iOS and Android alike) and which privacy usage keys
/// Info.plist declares. No device ids, no user data.
public struct AppReport: Codable, Equatable, Sendable {
    public var platform = "ios"
    public let package: String
    public let versionName: String
    public let sdks: [String]
    public let permissions: [String]

    public init(package: String, versionName: String, sdks: [String], permissions: [String]) {
        self.package = package
        self.versionName = versionName
        self.sdks = sdks
        self.permissions = permissions
    }

    /// Objective-C class names of vendor SDKs → tracker prefix. Swift-only SDK classes are not visible to
    /// NSClassFromString without their module name, hence the "Module.Class" entries.
    public static let probes: [(String, String)] = [
        ("FIRAnalytics", "com.google.firebase.analytics"),
        ("GADMobileAds", "com.google.android.gms.ads"),
        ("FBSDKApplicationDelegate", "com.facebook"),
        ("FBSDKCoreKit.ApplicationDelegate", "com.facebook"),
        ("TikTokBusiness", "com.tiktok"),
        ("Mixpanel", "com.mixpanel"),
        ("Mixpanel.Mixpanel", "com.mixpanel"),
        ("Amplitude", "com.amplitude"),
        ("AmplitudeSwift.Amplitude", "com.amplitude"),
        ("SEGAnalytics", "com.segment"),
        ("CleverTap", "com.clevertap"),
        ("MoEngage", "com.moengage"),
        ("MoEngageSDK.MoEngage", "com.moengage"),
        ("WebEngage", "com.webengage"),
        ("Smartech", "com.netcore"),
        ("Freshchat", "com.freshchat"),
        ("Intercom", "io.intercom"),
        ("AppsFlyerLib", "com.appsflyer"),
        ("Adjust", "com.adjust"),
        ("Branch", "io.branch"),
        ("FIRCrashlytics", "com.google.firebase.crashlytics"),
        ("FIRMessaging", "com.google.firebase.messaging"),
        ("OneSignal", "com.onesignal"),
        ("SentrySDK", "io.sentry"),
        ("Bugsnag", "com.bugsnag"),
        ("RazorpayCheckout", "com.razorpay"),
        ("Razorpay.RazorpayCheckout", "com.razorpay"),
        ("PhonePePPSDK", "com.phonepe"),
        ("STPAPIClient", "com.stripe"),
        ("TCTrueSDK", "com.truecaller"),
    ]

    /// Tracker prefixes whose probe class exists.
    public static func detect(_ exists: (String) -> Bool = { NSClassFromString($0) != nil }) -> [String] {
        var out: [String] = []
        for (cls, prefix) in probes where !out.contains(prefix) && exists(cls) { out.append(prefix) }
        return out
    }

    /// The report for the running app (Bundle.main).
    public static func current(bundle: Bundle = .main) -> AppReport {
        let info = bundle.infoDictionary ?? [:]
        return AppReport(
            package: bundle.bundleIdentifier ?? "unknown",
            versionName: info["CFBundleShortVersionString"] as? String ?? "0",
            sdks: detect(),
            permissions: info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
        )
    }
}
