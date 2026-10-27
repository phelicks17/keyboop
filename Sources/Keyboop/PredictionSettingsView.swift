import AppKit

/// Раздел настроек «Подсказки» (docs/inline-prediction.md).
///
/// Самодостаточный стек: строит и перестраивает себя сам, поэтому в `SettingsWindow` от него
/// только строчка в `buildSection`. Хелперы окна настроек приватны, здесь свои, попроще, но в
/// тех же размерах (заголовок 20 semibold, подписи 13 и 11, карточки `CardView`).
final class PredictionSettingsView: NSStackView {
    private var progress: Double?
    private var failed = false

    static func make() -> PredictionSettingsView {
        let v = PredictionSettingsView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = DS.itemGap
        v.rebuild()
        return v
    }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let s = PredictionSettings.self
        var views: [NSView] = [title(L10n.t("pred.title")), text(L10n.t("pred.body"), 13, .secondaryLabelColor)]

        views.append(card([switchRow("pred.enable", "pred.enableSub", s.enabled, #selector(toggleEnabled)), modelRow()]))
        if !LLMRuntime.isBundled { views.append(text(L10n.t("pred.noEngine"), 11, .systemOrange)) }

        let keys = NSPopUpButton()
        for k in s.acceptKeys { keys.addItem(withTitle: L10n.t("pred.key." + k.id)) }
        keys.selectItem(at: s.acceptKeys.firstIndex { $0.id == s.acceptKeyID } ?? 0)
        keys.target = self; keys.action = #selector(pickKey)
        views.append(card([
            row(L10n.t("pred.acceptKey"), L10n.t("pred.acceptSub"), keys),
            switchRow("pred.dictation", "pred.dictationSub", s.useDictation, #selector(toggleDictation)),
            switchRow("pred.screen", "pred.screenSub", s.screenContext, #selector(toggleScreen))
        ]))
        if s.screenContext {
            views.append(text(L10n.t("pred.screenNote"), 11, .tertiaryLabelColor))
            if !ScreenContext.hasPermission {
                let grant = NSButton(title: L10n.t("pred.screenGrant"), target: self, action: #selector(grantScreen))
                let open = NSButton(title: L10n.t("pred.screenOpen"), target: self, action: #selector(openScreenSettings))
                views.append(hstack([text(L10n.t("pred.screenPerm"), 13, .systemOrange), grant, open]))
            }
        }

        views.append(group(8))
        views.append(title(L10n.t("pred.excluded")))
        views.append(text(L10n.t("pred.excludedSub"), 13, .secondaryLabelColor))
        var appRows: [NSView] = s.excludedApps.map { bid in
            let remove = NSButton(title: L10n.t("pred.remove"), target: self, action: #selector(removeApp(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(bid)
            return row(Self.appName(bid), bid, remove)
        }
        appRows.append(row("", nil, addAppPopup()))
        views.append(card(appRows))
        views.append(text(L10n.t("pred.foot"), 11, .tertiaryLabelColor))

        for v in views {
            addArrangedSubview(v)
            if v is CardView || v is WrappingLabel { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        }
    }

    // MARK: - Модель

    private func modelRow() -> NSView {
        let m = PredictionModel.shared
        let sub = String(format: L10n.t("pred.modelSub"), L10n.size(PredictionModel.size))
        let trailing: NSView
        if let p = progress {
            let cancel = NSButton(title: L10n.t("pred.cancel"), target: self, action: #selector(cancelDownload))
            trailing = hstack([text(String(format: L10n.t("pred.downloading"), Int(p * 100)), 11, .secondaryLabelColor), cancel])
        } else if m.isInstalled {
            let del = NSButton(title: L10n.t("pred.delete"), target: self, action: #selector(deleteModel))
            trailing = hstack([text(L10n.t("pred.installed"), 11, .secondaryLabelColor), del])
        } else {
            trailing = NSButton(title: L10n.t("pred.download"), target: self, action: #selector(download))
        }
        return row(L10n.t("pred.model"), failed ? L10n.t("pred.downloadFailed") : sub, trailing)
    }

    @objc private func download() {
        failed = false
        progress = 0
        rebuildLater()
        PredictionModel.shared.download(progress: { [weak self] p in
            guard let self, let old = self.progress, Int(p * 100) != Int(old * 100) else { return }
            self.progress = p
            self.rebuild()
        }, done: { [weak self] ok in
            guard let self, self.progress != nil else { return }   // nil = человек сам отменил, это не ошибка
            self.progress = nil
            self.failed = !ok
            self.rebuild()
        })
    }
    @objc private func cancelDownload() {
        progress = nil
        PredictionModel.shared.cancel()
        rebuildLater()
    }
    @objc private func deleteModel() { PredictionModel.shared.delete { [weak self] _ in self?.rebuild() } }

    // MARK: - Переключатели

    // Перестройку откладываем на такт: на macOS 26 нельзя сносить NSSwitch изнутри его же action
    // (тот же приём, что у `toggleAuto` в SettingsWindow).
    private func rebuildLater() { DispatchQueue.main.async { [weak self] in self?.rebuild() } }

    @objc private func toggleEnabled(_ sw: NSSwitch) { PredictionSettings.enabled = sw.state == .on }
    @objc private func toggleDictation(_ sw: NSSwitch) { PredictionSettings.useDictation = sw.state == .on }
    @objc private func toggleScreen(_ sw: NSSwitch) {
        PredictionSettings.screenContext = sw.state == .on
        rebuildLater()
    }
    @objc private func pickKey(_ p: NSPopUpButton) {
        let i = p.indexOfSelectedItem
        guard PredictionSettings.acceptKeys.indices.contains(i) else { return }
        PredictionSettings.acceptKeyID = PredictionSettings.acceptKeys[i].id
    }
    @objc private func grantScreen() {
        ScreenContext.requestPermission()
        rebuildLater()
    }
    @objc private func openScreenSettings() { Permissions.openScreenRecordingSettings() }

    // MARK: - Исключения

    private func addAppPopup() -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.addItem(withTitle: L10n.t("pred.addApp"))
        let excluded = Set(PredictionSettings.excludedApps)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !excluded.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            p.addItem(withTitle: app.localizedName ?? app.bundleIdentifier!)
            p.lastItem?.representedObject = app.bundleIdentifier
        }
        p.target = self; p.action = #selector(addApp(_:))
        return p
    }
    @objc private func addApp(_ p: NSPopUpButton) {
        guard let bid = p.selectedItem?.representedObject as? String else { return }
        PredictionSettings.excludedApps.append(bid)
        rebuildLater()
    }
    @objc private func removeApp(_ b: NSButton) {
        guard let bid = b.identifier?.rawValue else { return }
        PredictionSettings.excludedApps.removeAll { $0 == bid }
        rebuildLater()
    }

    private static func appName(_ bid: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return bid }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Мелкие строительные блоки

    private func title(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 20, weight: .semibold)
        return l
    }
    private func text(_ t: String, _ size: CGFloat, _ color: NSColor) -> NSTextField {
        let l = WrappingLabel(string: t)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }
    private func group(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.alignment = .centerY; s.spacing = 8
        return s
    }
    private func switchRow(_ titleKey: String, _ subKey: String, _ on: Bool, _ action: Selector) -> NSView {
        let sw = NSSwitch()
        sw.state = on ? .on : .off
        sw.target = self; sw.action = action
        return row(L10n.t(titleKey), L10n.t(subKey), sw)
    }
    /// Строка карточки: заголовок и подпись слева, контрол справа.
    private func row(_ title: String, _ subtitle: String?, _ trailing: NSView) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        t.lineBreakMode = .byTruncatingTail
        var left: [NSView] = [t]
        if let subtitle {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabelColor
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            left.append(s)
        }
        let col = NSStackView(views: left)
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let r = NSStackView(views: [col, trailing])
        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 10
        r.distribution = .fill
        r.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        r.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return r
    }
    private func card(_ rows: [NSView]) -> CardView {
        let c = CardView()
        c.wantsLayer = true
        let v = NSStackView()
        v.orientation = .vertical; v.alignment = .width; v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = HairlineView()
                line.wantsLayer = true
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                v.addArrangedSubview(line)
            }
            v.addArrangedSubview(r)
        }
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            v.topAnchor.constraint(equalTo: c.topAnchor),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor)
        ])
        return c
    }
}
