#if canImport(UIKit) && !os(watchOS)
import UIKit

/// The consent notice as a UIKit screen (iOS 13+). Accept all, Reject all and Choose purposes share one style; purpose
/// switches start off unless already granted. A first-time notice cannot be swiped away (no implied consent).
public final class OrbitConsentViewController: UIViewController {
    private let consent = Orbit.consent
    private let stack = UIStackView()
    private var choose = false
    private var draft: [String: Bool] = [:]
    private var firstTime = true
    private var handlers: [Handler] = [] // target-action keeps iOS 13 support (UIAction is iOS 14+)

    private final class Handler: NSObject {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        @objc func fire() { f() }
    }

    private func on(_ c: UIControl, _ e: UIControl.Event, _ f: @escaping () -> Void) {
        let h = Handler(f)
        handlers.append(h)
        c.addTarget(h, action: #selector(Handler.fire), for: e)
    }

    /// Waits for the config, then presents the notice only if a choice is needed (first run or new notice version).
    public static func presentIfNeeded(from presenter: UIViewController) {
        var sub: OrbitSubscription?
        sub = Orbit.consent.onChange { [weak presenter] s in
            guard s.ready else { return }
            sub?.cancel()
            guard s.needsConsent else { return }
            DispatchQueue.main.async {
                guard let p = presenter, p.presentedViewController == nil else { return }
                p.present(OrbitConsentViewController(), animated: true)
            }
        }
        if Orbit.consent.snapshot().ready { sub?.cancel() }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        firstTime = consent.needsConsent
        isModalInPresentation = firstTime
        draft = Dictionary(uniqueKeysWithValues: (consent.config?.optional ?? []).map { ($0.code, consent.isGranted($0.code)) })
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let g = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: g.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        render()
    }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        handlers = []
        guard let cfg = consent.config else { return }
        let lang = consent.language
        let l = { (k: String) in cfg.label(lang, k) }
        view.semanticContentAttribute = lang == "ur" ? .forceRightToLeft : .forceLeftToRight

        stack.addArrangedSubview(label(cfg.org.name, .headline))
        if cfg.languages.count > 1 {
            let seg = UISegmentedControl(items: cfg.languages.map { NoticeConfig.languageNames[$0] ?? $0 })
            seg.selectedSegmentIndex = cfg.languages.firstIndex(of: lang) ?? 0
            seg.accessibilityLabel = l("language")
            on(seg, .valueChanged) { [weak self, weak seg] in
                guard let self, let i = seg?.selectedSegmentIndex, i >= 0 else { return }
                self.consent.language = cfg.languages[i]
                self.render()
            }
            stack.addArrangedSubview(seg)
        }
        stack.addArrangedSubview(label(cfg.summary(lang), .body))
        for (title, url) in [(l("readNotice"), cfg.noticeURL), (l("privacyCentre"), cfg.privacyCentreURL)] {
            guard let url else { continue }
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.contentHorizontalAlignment = .leading
            on(b, .touchUpInside) { UIApplication.shared.open(url) }
            stack.addArrangedSubview(b)
        }
        if choose {
            for p in cfg.purposes {
                let row = UIStackView()
                row.spacing = 8
                row.addArrangedSubview(label(p.title(lang), .subheadline))
                if p.essential {
                    row.addArrangedSubview(label(l("alwaysOn"), .footnote))
                } else {
                    let sw = UISwitch()
                    sw.isOn = draft[p.code] ?? false
                    sw.accessibilityLabel = p.title(lang)
                    on(sw, .valueChanged) { [weak self, weak sw] in self?.draft[p.code] = sw?.isOn ?? false }
                    row.addArrangedSubview(sw)
                }
                stack.addArrangedSubview(row)
                stack.addArrangedSubview(label(p.description(lang), .footnote))
            }
            stack.addArrangedSubview(button(l("save")) { [weak self] in self?.finish { $0.record($1) } })
        }
        // Same style and size for all three: rejecting is exactly as easy as accepting.
        stack.addArrangedSubview(button(l("acceptAll")) { [weak self] in self?.finish { c, _ in c.acceptAll() } })
        stack.addArrangedSubview(button(l("rejectAll")) { [weak self] in self?.finish { c, _ in c.rejectAll() } })
        if !choose { stack.addArrangedSubview(button(l("choose")) { [weak self] in self?.choose = true; self?.render() }) }
        if !firstTime { stack.addArrangedSubview(button(l("close")) { [weak self] in self?.dismiss(animated: true) }) }
    }

    private func finish(_ action: (OrbitConsent, [String: Bool]) -> Bool) {
        _ = action(consent, draft)
        dismiss(animated: true)
    }

    private func label(_ text: String, _ style: UIFont.TextStyle) -> UILabel {
        let v = UILabel()
        v.text = text
        v.font = .preferredFont(forTextStyle: style)
        v.adjustsFontForContentSizeCategory = true
        v.numberOfLines = 0
        return v
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .preferredFont(forTextStyle: .body)
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.systemBlue.cgColor
        b.layer.cornerRadius = 8
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        on(b, .touchUpInside, action)
        return b
    }
}
#endif
