import Foundation

/// ЗВУКИ-ЗАМИНКИ В ДИКТОВКЕ (просьба автора 26.10.2026). Модели честно записывают «э-э», «ммм»,
/// «хм», а в тексте они только мусор. Чистая функция без AppKit: проверяется стендом вне приложения.
///
/// Удаляем ТОЛЬКО звуки без смысла: «э», «ээ», «э-э-э», «эм», «мм», «м-м», «хм», «аа», «а-а» и
/// английские «um», «uh», «hmm», «erm». Слова «а», «ну», «ага», «ой», «эх» остаются: их говорят
/// намеренно. «мм» после числа тоже остаётся, это миллиметры.
///
/// Запятые, которые модель поставила вокруг заминки, уходят вместе с ней: «Я, э-э, думаю» → «Я
/// думаю». Если заминка начинала предложение с заглавной, заглавную получает следующее слово.
enum VoiceFillers {
    private static let regex: NSRegularExpression = {
        let filler = [
            "э+м*", "(?<ch>[эма])\\k<ch>*(?:-\\k<ch>+)+", "м{2,}", "х+м+", "а{2,}",
            "u+(?:h+m*|m+)", "er+m+", "h+m+",
        ].joined(separator: "|")
        // Граница слова — не буква, не цифра и не дефис («э-эффект» не трогаем). Перед «мм» не должно
        // стоять число («5 мм», «10мм»).
        let pattern = "(,[ \\t]*)?(?<![\\p{L}\\p{N}-])(?<!\\d[ \\t]?)(\(filler))(?![\\p{L}\\p{N}-])([ \\t]*,)?"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func strip(_ text: String) -> String {
        let ns = text as NSString
        // Слово целиком из заглавных («АА», «ММ») — обозначение или аббревиатура, а не заминка.
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter {
            let w = ns.substring(with: $0.range(at: 2))
            return !(w.count >= 2 && w == w.uppercased() && w != w.lowercased())
        }
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        var capitalizeNext = false     // заминка с заглавной «съела» начало предложения
        func append(_ chunk: String) {
            guard capitalizeNext, let i = chunk.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
                out += chunk; return
            }
            out += chunk[..<i] + String(chunk[i]).uppercased() + chunk[chunk.index(after: i)...]
            capitalizeNext = false
        }
        for m in matches {
            append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            if ns.substring(with: m.range(at: 2)).first?.isUppercase == true { capitalizeNext = true }
            cursor = m.range.location + m.range.length
        }
        append(ns.substring(from: cursor))
        // Подчистить следы: двойные пробелы, пробел перед знаком, пробелы по краям строк.
        let lines = out.components(separatedBy: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            l = l.replacingOccurrences(of: "[ \\t]+([.,!?…;:])", with: "$1", options: .regularExpression)
            // «Хорошо… э-э… ладно» не должно стать «Хорошо…… ладно».
            l = l.replacingOccurrences(of: "…{2,}", with: "…", options: .regularExpression)
            l = l.replacingOccurrences(of: "([,;])\\1+", with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: "^[ \\t]*[,;][ \\t]*", with: "", options: .regularExpression)
            return l.trimmingCharacters(in: .whitespaces)
        }
        let joined = lines.joined(separator: "\n")
        // Осталась одна пунктуация (вся диктовка была заминкой) — вставлять нечего.
        return joined.contains(where: { $0.isLetter || $0.isNumber }) ? joined : ""
    }
}
