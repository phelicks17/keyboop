import AppKit
import Carbon

extension Notification.Name {
    /// Любая настройка подсказок изменилась — предсказатель перечитывает свой кэш.
    static let keyboopPredictionSettingsChanged = Notification.Name("keyboopPredictionSettingsChanged")
}

/// Настройки подсказок продолжения. Свои ключи UserDefaults, а не поля `AppSettings`: функция
/// опциональная и целиком живёт в своих файлах (docs/inline-prediction.md).
enum PredictionSettings {
    private static let d = UserDefaults.standard
    private static let enabledKey = "predictEnabled"
    private static let screenKey = "predictScreenContext"
    private static let dictationKey = "predictUseDictation"
    private static let acceptKey = "predictAcceptKey"
    private static let excludedKey = "predictExcludedApps"
    private static let seededKey = "predictSeededExclusions"

    /// Менеджеры паролей: подсказывать там нечего, а снимок экрана там недопустим.
    static let defaultExcluded = ["com.1password.1password", "com.agilebits.onepassword7",
                                  "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"]

    /// Клавиши принятия: значение настройки → (keyCode, подпись на подсказке).
    static let acceptKeys: [(id: String, keyCode: Int64, label: String)] = [
        ("tab", 48, "⇥"),
        ("right", 124, "→")
    ]

    static var enabled: Bool {
        // Не зарегистрировано → false: ВЫКЛ по умолчанию. На Intel выключено всегда: движка там нет,
        // и горячий путь тапа не должен даже взводить таймер.
        #if arch(arm64)
        get { d.bool(forKey: enabledKey) }
        #else
        get { false }
        #endif
        set { d.set(newValue, forKey: enabledKey); changed() }
    }
    static var screenContext: Bool {
        get { d.bool(forKey: screenKey) }    // ВЫКЛ по умолчанию, отдельное согласие
        set { d.set(newValue, forKey: screenKey); changed() }
    }
    static var useDictation: Bool {
        get { d.object(forKey: dictationKey) as? Bool ?? true }
        set { d.set(newValue, forKey: dictationKey); changed() }
    }
    static var acceptKeyID: String {
        get { d.string(forKey: acceptKey) ?? "tab" }
        set { d.set(newValue, forKey: acceptKey); changed() }
    }
    static var acceptKeyEntry: (id: String, keyCode: Int64, label: String) {
        acceptKeys.first { $0.id == acceptKeyID } ?? acceptKeys[0]
    }
    static var excludedApps: [String] {
        get {
            if !d.bool(forKey: seededKey) {
                d.set(true, forKey: seededKey)
                d.set(defaultExcluded, forKey: excludedKey)
            }
            return d.stringArray(forKey: excludedKey) ?? []
        }
        set { d.set(newValue, forKey: excludedKey); changed() }
    }

    private static func changed() {
        NotificationCenter.default.post(name: .keyboopPredictionSettingsChanged, object: nil)
    }
}

/// Подсказка продолжения: пауза в наборе → контекст → локальная модель → призрачный текст →
/// клавиша принятия вставляет. Всё на main, кроме AX-чтений (своя очередь) и модели (LLMRuntime).
final class InlinePredictor {
    static let shared = InlinePredictor()

    /// Пауза после последней клавиши, после которой спрашиваем модель.
    private let debounce: TimeInterval = 0.3
    /// Забытая подсказка не должна висеть над полем вечно.
    private let autoHide: TimeInterval = 8
    private let minContext = 3
    private let maxTokens = 16

    private let axQueue = DispatchQueue(label: "keyboop.predict.ax", qos: .userInitiated)
    private var enabled = PredictionSettings.enabled
    private var acceptKeyCode = PredictionSettings.acceptKeyEntry.keyCode
    private var timer: Timer?
    private var hideTimer: Timer?
    private var cancel: LLMRuntime.Cancel?
    /// Растёт на каждом нажатии: ответ, пришедший к устаревшему поколению, выбрасывается.
    private var generation = 0
    private var suggestion: String?
    private var monitorsInstalled = false
    private var overlayUsed = false

    private init() {
        NotificationCenter.default.addObserver(forName: .keyboopPredictionSettingsChanged, object: nil,
                                               queue: .main) { [weak self] _ in self?.reloadSettings() }
    }

    private func reloadSettings() {
        enabled = PredictionSettings.enabled
        acceptKeyCode = PredictionSettings.acceptKeyEntry.keyCode
        if !PredictionSettings.screenContext { ScreenContext.forget() }
        if !enabled {
            dismiss()
            ScreenContext.forget()
            LLMRuntime.shared.unload()
        }
    }

    // MARK: - Горячий путь тапа

    /// Зовётся из колбэка `EventTap` (main) на каждом keyDown. true — клавишу проглотить: это было
    /// принятие подсказки. Выключенная функция стоит одного сравнения.
    func tapKeyDown(keyCode: Int64, mods: CGEventFlags) -> Bool {
        guard enabled else { return false }
        if keyCode == acceptKeyCode, mods.isEmpty, let text = suggestion, overlayUsed, GhostTextOverlay.shared.isVisible {
            accept(text)
            return true
        }
        dismiss()
        installMonitorsOnce()
        timer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { [weak self] _ in self?.predict() }
        return false
    }

    // MARK: - Подсказка

    private func dismiss() {
        generation += 1
        cancel?.cancel(); cancel = nil
        timer?.invalidate(); timer = nil
        hideTimer?.invalidate(); hideTimer = nil
        suggestion = nil
        // Панель трогаем, только если её уже показывали: первое нажатие не должно создавать окно
        // внутри колбэка тапа.
        if overlayUsed { GhostTextOverlay.shared.hide() }
    }

    private func accept(_ text: String) {
        dismiss()
        // Та же печать, что у диктовки и сниппетов: Unicode-синтетика, буфер обмена не трогаем,
        // раскладку не переключаем. Уведомление диктовки заставляет Engine забыть набранное слово:
        // в поле появился текст, которого человек не печатал (Engine, keyboopVoiceInserted).
        let startedAt = ProcessInfo.processInfo.systemUptime
        TextReplacer.insert(text) { [weak self] in
            NotificationCenter.default.post(name: .keyboopVoiceInserted, object: nil, userInfo: ["startedAt": startedAt])
            // Следующая подсказка сразу за принятой: наша синтетика в tapKeyDown не попадает,
            // и без этого цепочка обрывалась бы до следующей клавиши человека.
            guard let self, self.enabled, self.timer == nil else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: self.debounce, repeats: false) { [weak self] _ in self?.predict() }
        }
        kbLog("подсказки: принята, \(text.count) симв.")
    }

    /// Причина промолчать, если она есть. Проверки дешёвые, AX — отдельно и не на main.
    private func blocker(_ app: NSRunningApplication?) -> String? {
        if Pause.active { return "пауза" }
        if VoiceController.shared.isRecording || VoiceController.shared.isBusyWithDictation { return "диктовка" }
        if IsSecureEventInputEnabled() { return "secure input" }
        if !PredictionModel.shared.isInstalled || !LLMRuntime.isBundled { return "нет модели или движка" }
        guard let app, let bid = app.bundleIdentifier else { return "нет переднего приложения" }
        if bid == Bundle.main.bundleIdentifier { return "своё окно" }
        if PredictionSettings.excludedApps.contains(bid) || ExceptionStore.shared.appMode(bid) == "off" { return "исключение" }
        return nil
    }

    private func predict() {
        timer = nil
        let app = NSWorkspace.shared.frontmostApplication
        guard enabled, blocker(app) == nil, let pid = app?.processIdentifier else { return }
        let gen = generation
        axQueue.async { [weak self] in
            // Поле пароля или нечитаемое поле: ни подсказки, ни снимка экрана.
            guard SecureInputPolicy.focusedFieldVerdict() == .ordinary,
                  let before = AXScreenCheck.textBeforeCaret(maxLen: 1500),
                  let caret = CaretLocator.caretScreenRect() else { return }
            DispatchQueue.main.async { self?.ask(before: before, caret: caret, pid: pid, gen: gen) }
        }
    }

    private func ask(before: String, caret: NSRect, pid: pid_t, gen: Int) {
        guard gen == generation, before.count >= minContext else { return }
        var screen: String?
        if PredictionSettings.screenContext {
            ScreenContext.refreshIfStale(pid: pid)
            screen = ScreenContext.text(for: pid)
        }
        let dictation = PredictionSettings.useDictation ? VoiceHistory.shared.lastVisible()?.text : nil
        let prompt = PredictionPrompt.build(.init(beforeCaret: before, dictation: dictation, screen: screen))
        let c = LLMRuntime.Cancel()
        cancel = c
        LLMRuntime.shared.complete(prompt, maxTokens: maxTokens, cancel: c) { [weak self] raw in
            guard let self, gen == self.generation, let raw,
                  let text = PredictionPrompt.clean(raw, beforeCaret: before) else { return }
            self.suggestion = text
            self.overlayUsed = true
            GhostTextOverlay.shared.show(text, at: caret, keyName: PredictionSettings.acceptKeyEntry.label)
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: self.autoHide, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    /// Клик мышью двигает каретку, смена приложения уносит поле: подсказка там уже ложь.
    /// Ставим один раз и только когда функция впервые понадобилась.
    private func installMonitorsOnce() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            self?.dismiss()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.dismiss()
            ScreenContext.forget()
        }
    }
}
