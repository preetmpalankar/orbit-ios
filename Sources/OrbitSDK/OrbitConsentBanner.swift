#if canImport(SwiftUI) && canImport(Combine)
import Combine
import SwiftUI

@available(iOS 15.0, macOS 12.0, *)
final class BannerModel: ObservableObject {
    @Published var snapshot: ConsentSnapshot
    private var bag: AnyCancellable?
    init(_ consent: OrbitConsent) {
        snapshot = consent.snapshot()
        bag = consent.publisher.receive(on: DispatchQueue.main).sink { [weak self] in self?.snapshot = $0 }
    }
}

/// The consent notice as a SwiftUI card. With `forceOpen` false (default) it appears only when a choice is needed
/// (first run, or a new notice version) and hides once the person chooses. Pass `forceOpen: true` with `onClose` to
/// re-open it from a "Privacy choices" setting. Accept all, Reject all and Choose purposes have equal weight.
@available(iOS 15.0, macOS 12.0, *)
public struct OrbitConsentBanner: View {
    @StateObject private var model = BannerModel(Orbit.consent)
    @State private var choose = false
    @State private var draft: [String: Bool] = [:]
    @State private var lang = Orbit.consent.language
    private let forceOpen: Bool
    private let onClose: () -> Void

    public init(forceOpen: Bool = false, onClose: @escaping () -> Void = {}) {
        self.forceOpen = forceOpen
        self.onClose = onClose
    }

    public var body: some View {
        let consent = Orbit.consent
        if let cfg = consent.config, model.snapshot.canShowBanner, model.snapshot.needsConsent || forceOpen {
            let first = model.snapshot.needsConsent
            let l = { (k: String) in cfg.label(lang, k) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(cfg.org.name).font(.headline)
                    if cfg.languages.count > 1 {
                        Picker(l("language"), selection: $lang) {
                            ForEach(cfg.languages, id: \.self) { Text(NoticeConfig.languageNames[$0] ?? $0).tag($0) }
                        }
                        .onChange(of: lang) { consent.language = $0 }
                    }
                    Text(cfg.summary(lang)).font(.body)
                    if let u = cfg.noticeURL { Link(l("readNotice"), destination: u) }
                    if let u = cfg.privacyCentreURL { Link(l("privacyCentre"), destination: u) }
                    if choose {
                        ForEach(cfg.purposes, id: \.code) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                if p.essential {
                                    HStack { Text(p.title(lang)).bold(); Spacer(); Text(l("alwaysOn")) }
                                } else {
                                    Toggle(p.title(lang), isOn: Binding(get: { draft[p.code] ?? false }, set: { draft[p.code] = $0 }))
                                }
                                Text(p.description(lang)).font(.footnote)
                            }
                        }
                        equal(l("save")) { done { consent.record(draft) } }
                    }
                    // Same style and size for all three: rejecting is exactly as easy as accepting.
                    equal(l("acceptAll")) { done { consent.acceptAll() } }
                    equal(l("rejectAll")) { done { consent.rejectAll() } }
                    if !choose {
                        equal(l("choose")) {
                            draft = Dictionary(uniqueKeysWithValues: cfg.optional.map { ($0.code, consent.isGranted($0.code)) })
                            choose = true
                        }
                    }
                    if !first { equal(l("close")) { choose = false; onClose() } }
                }
                .padding()
            }
            .environment(\.layoutDirection, lang == "ur" ? .rightToLeft : .leftToRight)
            .onChange(of: consent.principalId) { _ in choose = false; draft = [:] }
            .onDisappear { choose = false; draft = [:] }
        }
    }

    private func done(_ action: () -> Void) { action(); choose = false; onClose() }

    private func equal(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }.buttonStyle(.bordered)
    }
}
#endif
