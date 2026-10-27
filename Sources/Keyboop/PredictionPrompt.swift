import Foundation

/// Сборка промпта для подсказки продолжения и чистка ответа модели (docs/inline-prediction.md).
///
/// Чистая логика без AppKit и без сети: всё, что сюда приходит, уже прочитано локально, и всё,
/// что отсюда уходит, идёт только в локальную модель. Отдельным файлом, чтобы проверять без Mac.
enum PredictionPrompt {
    /// Сколько текста каждого источника кладём в промпт. Больше не помогает модели в 2B, а
    /// длинный промпт это задержка первого токена на каждой паузе.
    static let maxBeforeCaret = 1200
    static let maxScreen = 1500
    static let maxDictation = 400
    /// Хвост текущей строки, которым предзаполняется ответ модели.
    static let maxTail = 120
    /// Подсказка длиннее этого режется по границе слова: это подсказка, а не абзац.
    static let maxSuggestion = 60

    struct Context {
        var beforeCaret: String
        var dictation: String?
        var screen: String?
    }

    /// Промпт в формате ходов Gemma 4, ответ предзаполнен хвостом текущей фразы: модель
    /// продолжает его, а не пересказывает весь текст.
    static func build(_ c: Context) -> String {
        let before = String(sanitize(c.beforeCaret).suffix(maxBeforeCaret))
        var user = ""
        if let s = c.screen.map(sanitize), !s.isEmpty {
            user += "Text visible on screen (OCR, may be noisy):\n" + String(s.prefix(maxScreen)) + "\n\n"
        }
        if let d = c.dictation.map(sanitize), !d.isEmpty {
            user += "Recently dictated by the user:\n" + String(d.suffix(maxDictation)) + "\n\n"
        }
        user += "Text being typed:\n" + before
        // <bos> сюда не пишем: его добавляет токенизатор (kb_llm_complete, add_special).
        return "<|turn>system\n"
            + "You are an autocomplete engine. Continue the text being typed from exactly where it stops. "
            + "Write only the next few words, in the same language and style. Never repeat what is already "
            + "written. Use the other context only as background.<turn|>\n"
            + "<|turn>user\n" + user + "<turn|>\n"
            + "<|turn>model\n" + tail(of: before)
    }

    /// Хвост текущей строки для предзаполнения ответа: после последнего перевода строки, не длиннее
    /// maxTail и, если пришлось резать, с начала слова (обрубок слова в начале сбивает модель).
    static func tail(of text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard line.count > maxTail else { return line }
        let cut = String(line.suffix(maxTail))
        guard let sp = cut.firstIndex(of: " ") else { return cut }
        return String(cut[cut.index(after: sp)...])
    }

    /// Ответ модели → текст подсказки или nil, если показывать нечего.
    /// `beforeCaret` нужен для стыка: два пробела подряд на границе не нужны.
    static func clean(_ raw: String, beforeCaret: String) -> String? {
        var s = raw
        // Обрезаем по первому концу предложения: дальше модель чаще фантазирует, чем угадывает.
        if let end = s.firstIndex(where: { ".!?…".contains($0) }) {
            s = String(s[...end])
        }
        if beforeCaret.last?.isWhitespace == true {
            while s.first == " " { s.removeFirst() }
        }
        while s.last?.isWhitespace == true { s.removeLast() }
        if s.count > maxSuggestion {
            let cut = String(s.prefix(maxSuggestion))
            s = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        }
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return s
    }

    /// Чужой текст (экран, поле, диктовка) не должен превратиться в служебные токены Gemma:
    /// промпт токенизируется с разбором спецтокенов, и строка «<turn|>» на экране закрыла бы ход.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "|>", with: "| >")
            .replacingOccurrences(of: "<bos>", with: "< bos>")
            .replacingOccurrences(of: "<eos>", with: "< eos>")
    }
}
