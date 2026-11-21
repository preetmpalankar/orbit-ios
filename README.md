# Orbit SDK by JuriCloud: iOS

DPDP Act 2023 consent for iOS apps. It shows your Orbit consent notice, records each person's choices with Orbit and
tells your code which purposes it may use, so analytics, advertising and marketing SDKs stay off until the person
consents. Swift Package, iOS 13+ (SwiftUI banner iOS 15+), no third-party dependencies.

## Install

Xcode → File → Add Package Dependencies → `https://github.com/preetmpalankar/orbit-ios` (version 1.0.1), or:

```swift
.package(url: "https://github.com/preetmpalankar/orbit-ios", from: "1.0.1")
// target: .product(name: "OrbitSDK", package: "orbit-ios")
```

**In Orbit:** create a public key (`pk_live_…`) for the app and add `app:<your bundle id>` (for example
`app:com.acme.shop`) to its allowed origins. The SDK sends your bundle id in an `X-Orbit-App` header, and Orbit only
accepts the key from apps listed there. Never put a secret key (`sk_live_…`) in an app.

## Quick start

```swift
import OrbitSDK

// AppDelegate.application(_:didFinishLaunchingWithOptions:) or your App's init
Orbit.start(publicKey: "pk_live_xxxxxxxxxxxx")
```

```swift
Orbit.consent.isGranted("analytics")       // true only for granted or essential purposes
Orbit.consent.state("analytics")           // .granted | .denied | .withdrawn | .essential | .unknown
Orbit.consent.record(["analytics": true, "marketing": false]) // full set; others become denied
Orbit.consent.acceptAll(); Orbit.consent.rejectAll()
Orbit.consent.withdraw("marketing")        // one purpose, others unchanged (DPDP s.6(4))
Orbit.identify("user_8f2a91c4")            // after login: your opaque user id, 8–128 chars. Never an email or phone.
Orbit.principalId                          // "anon_<uuid>" until identify()

let sub = Orbit.consent.onChange { snapshot in … }   // called now and after every change; sub.cancel() to stop
Orbit.consent.publisher.sink { snapshot in … }        // Combine
for await snapshot in Orbit.consent.changes() { … }    // async stream
```

When **Consent → Banner → After login** is enabled, call `Orbit.identify` after authentication or session restoration, and `Orbit.resetIdentity()` on sign-out. Mounted SwiftUI banners react to identity changes. For the one-shot presenter, call `OrbitConsentViewController.presentIfNeeded(from:)` from the signed-in screen after identifying the user.

Purpose codes are the ones in your Orbit dashboard. `record` returns false until the notice config has loaded. Before
`Orbit.start` is called, `Orbit.consent` is an inert instance: every non-essential purpose is not granted and nothing is
sent.

## Showing the notice

Show the notice before any non-essential processing, and give people a way to re-open it (withdrawing must be as easy
as giving). Both UIs put Accept all, Reject all and Choose purposes on equal buttons, start every purpose switch off,
use the person's language from your Orbit config, and link the full notice and privacy centre. A first-time notice
cannot be dismissed without a choice.

**SwiftUI** (iOS 15+):
```swift
ZStack(alignment: .bottom) {
    ContentView()
    OrbitConsentBanner()                       // appears only when a choice is needed
}
// Settings → "Privacy choices":
.sheet(isPresented: $showChoices) { OrbitConsentBanner(forceOpen: true) { showChoices = false } }
```

**UIKit** (iOS 13+):
```swift
override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    OrbitConsentViewController.presentIfNeeded(from: self)   // first run, or a new notice version
}
// Settings → "Privacy choices":
present(OrbitConsentViewController(), animated: true)
```

When you publish a new notice version in Orbit, earlier choices no longer count: `isGranted` returns false for
non-essential purposes and both UIs ask again.

## Gating third-party SDKs

Start each SDK switched off, then follow Orbit. `onChange` runs immediately with the current state and again after
every change, including withdrawal.

**Firebase Analytics.** In Info.plist set `FIREBASE_ANALYTICS_COLLECTION_ENABLED` to `NO`, and
`GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE` / `_AD_USER_DATA` / `_AD_PERSONALIZATION_SIGNALS` to `NO`. Then:
```swift
Orbit.consent.onChange { s in
    Analytics.setAnalyticsCollectionEnabled(s.isGranted("analytics"))
    let ads: ConsentStatus = s.isGranted("advertising") ? .granted : .denied   // FirebaseAnalytics.ConsentStatus
    Analytics.setConsent([.adStorage: ads, .adUserData: ads, .adPersonalization: ads])
}
```
(Both modules define `ConsentStatus`; qualify it as `FirebaseAnalytics.ConsentStatus` if the compiler asks.)

**AppsFlyer.**
```swift
Orbit.consent.onChange { s in
    AppsFlyerLib.shared().isStopped = !s.isGranted("attribution")
    if s.isGranted("attribution") { AppsFlyerLib.shared().start() }
}
```

**CleverTap.**
```swift
Orbit.consent.onChange { s in CleverTap.sharedInstance()?.setOptOut(!s.isGranted("marketing")) }
```

Listeners run on the thread that made the change (main for a button tap, a background thread when the config loads).
Hop to the main actor yourself for UI work.

## App Tracking Transparency

Orbit never reads the IDFA and does not link AdSupport or AppTrackingTransparency, so it needs no ATT prompt and no
`NSUserTrackingUsageDescription`. ATT and DPDP consent are separate: if an SDK you gate also tracks across apps, you still
need the ATT prompt for it, and Orbit's "advertising" choice should be granted as well before you start that SDK.

## Optional app privacy report

```swift
Orbit.start(publicKey: "pk_live_…", appReport: true)   // off by default
```
Once per app version (`CFBundleShortVersionString`), Orbit receives your bundle id, version, which known third-party
SDKs are linked (checked with `NSClassFromString` on one class per vendor, for example `AppsFlyerLib`) and which privacy
usage keys (`NS…UsageDescription`) your Info.plist declares. No device ids, no user data. Pure-Swift SDK classes whose
module name differs from the list may be missed.

## What is sent and stored

Sent to Orbit (TLS only, `https://apidpdp-orbit.juricloud.co/api/v1` unless you pass `apiURL`) over an ephemeral
`URLSession` (no cookies, no cache): the principal id, the language, the notice version and the choices. Headers:
`X-Orbit-App` (bundle id) and `User-Agent: orbit-ios/1.0.1`. The key is never logged.

Stored in `Application Support/Orbit/orbit.json` (written atomically, file protection "until first unlock"): the
principal id, `{v, at, choices}`, records not yet confirmed by the server, the last notice config, the chosen language
and the last reported app version.

## Failure modes

| Situation | Behaviour |
|---|---|
| Orbit unreachable at first launch | No config, nothing to show; every non-essential purpose reads **not granted**. Retried next launch. |
| Orbit unreachable later | The cached config is used; stored choices still apply. |
| Network fails while recording | The choice applies locally at once. The record waits on disk and is resent with exponential backoff (2 s … 5 min) while the app runs, and again on next launch. |
| Server rejects a record with 400/404/422 | Dropped (resending cannot succeed). |
| 401/403 (key revoked, app not allowed), 408, 429, 5xx | Kept and retried, so fixing the key in Orbit recovers the records. |
| More than 500 unsent records | The oldest are dropped. |
| Invalid key or non-https `apiURL` passed to `start` | `assertionFailure` in debug builds; in release Orbit stays inert (nothing granted, nothing sent). |

Network calls never run on the main thread.

## Development

```
swift test
```
With only the Command Line Tools installed (no Xcode), Swift Testing needs its framework path:
```
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc $F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
```
