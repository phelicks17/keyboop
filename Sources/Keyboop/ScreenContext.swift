import AppKit
import ScreenCaptureKit
import Vision

/// Текст с экрана для подсказок продолжения: снимок переднего окна → Vision OCR на устройстве.
///
/// ⚠️ КАРТИНКА НИКУДА НЕ ИДЁТ. `CGImage` живёт ровно до конца распознавания: не кодируется, не
/// пишется на диск, не логируется, в сеть не уходит. Хранится только распознанный текст, в памяти,
/// не дольше `maxAge`, и сбрасывается при смене приложения. Решение о том, МОЖНО ли снимать
/// (пароли, исключения, пауза), принимает `InlinePredictor` до вызова `refresh`.
///
/// Нужен отдельный доступ «Запись экрана». Без него `refresh` молча ничего не делает: просить
/// доступ можно только по кнопке в настройках, а не из-под набора текста.
enum ScreenContext {
    /// Не чаще одного снимка за это время: OCR окна стоит десятые доли секунды CPU/ANE.
    static let minInterval: TimeInterval = 20
    /// Старше этого текст не отдаём: экран давно другой.
    static let maxAge: TimeInterval = 60

    private static var cached: (pid: pid_t, text: String, at: Date)?
    private static var lastAttempt = Date.distantPast
    private static var inFlight = false

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Системный запрос доступа. Зовётся только по кнопке в настройках.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    /// Свежий текст для этого процесса или nil. Только main.
    static func text(for pid: pid_t) -> String? {
        guard let c = cached, c.pid == pid, Date().timeIntervalSince(c.at) < maxAge else { return nil }
        return c.text
    }

    /// Забыть всё распознанное (выключили тумблер, сменили приложение, экран заблокирован).
    static func forget() { cached = nil }

    /// Обновить текст в фоне, если пора. Только main. Результат появится к одной из следующих
    /// подсказок: текущую мы снимком не задерживаем.
    static func refreshIfStale(pid: pid_t) {
        if let c = cached, c.pid != pid { cached = nil }
        guard !inFlight, hasPermission, Date().timeIntervalSince(lastAttempt) >= minInterval else { return }
        guard #available(macOS 14.0, *) else { return }   // SCScreenshotManager есть с 14; Intel на 13 живёт без экрана
        lastAttempt = Date()
        inFlight = true
        Task.detached(priority: .utility) {
            let text = await capture(pid: pid)
            await MainActor.run {
                inFlight = false
                // Пока снимали, человек мог переключиться: текст чужого окна не нужен.
                guard let text, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                cached = (pid, text, Date())
            }
        }
    }

    @available(macOS 14.0, *)
    private static func capture(pid: pid_t) async -> String? {
        guard let windowID = frontWindowID(pid: pid),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        // Двукратный масштаб для мелкого шрифта, но не больше 2560 по ширине: дальше OCR только дороже.
        let scale = min(2.0, 2560 / max(window.frame.width, 1))
        cfg.width = Int(window.frame.width * scale)
        cfg.height = Int(window.frame.height * scale)
        cfg.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else {
            return nil
        }
        return recognize(image)
    }

    /// Верхнее окно обычного уровня у процесса: CGWindowList отдаёт окна спереди назад.
    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            return id
        }
        return nil
    }

    private static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate          // .fast не знает кириллицу
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { return nil }
        // Сверху вниз (у Vision y растёт вверх), строками.
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(PredictionPrompt.maxScreen))
    }
}
