import Foundation
#if arch(arm64)

/// Распознавание речи через GigaAM v3 e2e (Сбер, ai-sage/GigaAM-v3) на ONNX Runtime. Только
/// русский, зато с пунктуацией и нормализацией текста прямо из модели. Офлайн: в рантайме сети нет,
/// модель качается только по кнопке в настройках. Вычисления — в `GigaAMCore.swift`.
///
/// # Откуда файлы и почему им можно верить
///
/// В официальном ai-sage/GigaAM-v3 (ревизии e2e_ctc `cec030b4…`, e2e_rnnt `7655ad71…`) лежат только
/// PyTorch-веса, запустить их в приложении нечем. ONNX берём из istupakov/gigaam-v3-onnx (MIT,
/// экспорт для onnx-asr), запиненного на коммит. Проверено стендом 25.10.2026: наш собственный
/// экспорт официальных весов штатным `to_onnx` даёт те же выходы с расхождением ровно 0.0 у всех
/// трёх частей RNN-T и у CTC, а текст на эталонных записях совпадает с PyTorch побуквенно. Как и у
/// whisper, после скачивания сверяем SHA-256 каждого файла; несовпадение — файл не ставится.
final class GigaAMEngine {
    static let shared = GigaAMEngine()

    /// Неизменяемый коммит istupakov/gigaam-v3-onnx (18.02.2026), на который пиннятся все файлы.
    private static let pinnedRevision = "322c3b29492673eb7d0b434bfa9dfb8653e34d02"

    struct File {
        let name: String
        let bytes: Int64        // размер — дешёвая отсечка обрыва до хеширования сотен мегабайт
        let sha256: String
    }
    /// Вариант модели в списке настроек. Ключи L10n явные, по той же причине, что у whisper
    /// (`ModelDownloader.Model`): вычисленный из id ключ однажды уже показал чужие цифры.
    struct Variant {
        let id: String
        let kind: GigaAMModel.Kind
        let name: String        // ключ L10n
        let size: String        // EN-единицы, локализуются через L10n.size()
        let note: String        // ключ L10n
        let help: String        // ключ L10n
        let vocab: File
        let models: [File]      // ctc: [модель]; rnnt: [encoder, decoder, joint]
    }

    private static let ctcVocab = File(name: "v3_e2e_ctc_vocab.txt", bytes: 2_007,
        sha256: "142de7570b3de5b3035ce111a89c228e80e6085273731d944093ddf24fa539cd")
    private static let rnntVocab = File(name: "v3_e2e_rnnt_vocab.txt", bytes: 13_354,
        sha256: "39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7")

    static let catalog: [Variant] = [
        Variant(id: "gigaam-v3-e2e-rnnt", kind: .rnnt, name: "gigaam.rnnt.name", size: "892 MB",
                note: "gigaam.rnnt.note", help: "gigaam.rnnt.help", vocab: rnntVocab, models: [
            File(name: "v3_e2e_rnnt_encoder.onnx", bytes: 885_084_534,
                 sha256: "cd60b3764a832e8560ae6d3ad0b10adc1a42ffae412b9476f25620aae4f4a508"),
            File(name: "v3_e2e_rnnt_decoder.onnx", bytes: 4_599_910,
                 sha256: "7b0a16d67fd2cb37061decc93c69e364a9ab27afee3c57495d55b1c974cf7231"),
            File(name: "v3_e2e_rnnt_joint.onnx", bytes: 2_712_896,
                 sha256: "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c")]),
        Variant(id: "gigaam-v3-e2e-rnnt-int8", kind: .rnnt, name: "gigaam.rnntq.name", size: "226 MB",
                note: "gigaam.rnntq.note", help: "gigaam.rnntq.help", vocab: rnntVocab, models: [
            File(name: "v3_e2e_rnnt_encoder.int8.onnx", bytes: 224_570_477,
                 sha256: "4e0e076a6076cd110277e529b8ac8f32cd5297f7fbebad5341ae8ddb7d00817b"),
            File(name: "v3_e2e_rnnt_decoder.int8.onnx", bytes: 1_159_170,
                 sha256: "89014e134865615b91e037157e46e389b1271e6072460efc010ea08e61e23146"),
            File(name: "v3_e2e_rnnt_joint.int8.onnx", bytes: 687_791,
                 sha256: "ade116563dbf66e503b0994efab6b5861412743e52bf31c39fc3fffa3783d5d1")]),
        Variant(id: "gigaam-v3-e2e-ctc", kind: .ctc, name: "gigaam.ctc.name", size: "886 MB",
                note: "gigaam.ctc.note", help: "gigaam.ctc.help", vocab: ctcVocab, models: [
            File(name: "v3_e2e_ctc.onnx", bytes: 885_950_079,
                 sha256: "377701bd33568f4733feec2db5b2dc12544fd09a5a5dfa69ccf55d161f84027a")]),
        Variant(id: "gigaam-v3-e2e-ctc-int8", kind: .ctc, name: "gigaam.ctcq.name", size: "225 MB",
                note: "gigaam.ctcq.note", help: "gigaam.ctcq.help", vocab: ctcVocab, models: [
            File(name: "v3_e2e_ctc.int8.onnx", bytes: 224_893_347,
                 sha256: "2e3fcb7a7b66030336fd10c2fcfb033bd1dc7e1bf238fe5cfd83b1d0cfc9d28e")]),
    ]

    static func variant(_ id: String) -> Variant? { catalog.first { $0.id == id } }

    /// Папка варианта: models/gigaam/<id>/. Файлы попадают туда только после проверки хеша,
    /// поэтому «все на месте» и значит «установлена».
    static func dir(_ id: String) -> URL {
        VoiceController.modelsDir.appendingPathComponent("gigaam/\(id)", isDirectory: true)
    }
    static func isInstalled(_ id: String) -> Bool {
        guard let v = variant(id) else { return false }
        return ([v.vocab] + v.models).allSatisfy {
            FileManager.default.fileExists(atPath: dir(id).appendingPathComponent($0.name).path)
        }
    }
    /// Выбранный вариант скачан?
    static var modelInstalled: Bool { isInstalled(AppSettings.shared.gigaamModel) }

    // Состояние меняется только на `queue`; `lock` — чтобы `ready` можно было честно читать с main.
    private let queue = DispatchQueue(label: "keyboop.gigaam", qos: .userInitiated)
    private let lock = NSLock()
    private var model: GigaAMModel?
    private var loadedId: String?
    private static var runtime: OrtRuntime?
    private static var runtimeFailed = false

    /// Загружена именно выбранная сейчас модель.
    var ready: Bool {
        lock.lock(); defer { lock.unlock() }
        return model != nil && loadedId == AppSettings.shared.gigaamModel
    }

    /// Загрузить выбранную модель. Последовательная очередь сама склеивает параллельные заявки:
    /// вторая дождётся первой и увидит уже готовую модель, двойной загрузки не будет.
    func loadIfNeeded() async -> Bool {
        let id = AppSettings.shared.gigaamModel
        return await withCheckedContinuation { c in queue.async { c.resume(returning: self.loadNow(id)) } }
    }

    private func loadNow(_ id: String) -> Bool {
        if model != nil && loadedId == id { return true }
        guard let v = Self.variant(id), Self.isInstalled(id) else { kbLog("gigaam: модель \(id) не установлена"); return false }
        guard let rt = Self.loadRuntime() else { return false }
        setModel(nil, nil)                                  // старый вариант отпускаем ДО загрузки нового
        let t0 = ProcessInfo.processInfo.systemUptime
        do {
            let d = Self.dir(id)
            let m = try GigaAMModel(kind: v.kind, runtime: rt, vocabPath: d.appendingPathComponent(v.vocab.name).path,
                                    models: v.models.map { d.appendingPathComponent($0.name).path },
                                    threads: WhisperBridge.transcribeThreads)
            setModel(m, id)
            kbLog("gigaam: \(id) загружена за \(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000))мс")
            return true
        } catch {
            kbLog("gigaam: загрузка \(id) не удалась: \(error)")
            return false
        }
    }

    private func setModel(_ m: GigaAMModel?, _ id: String?) {
        lock.lock(); model = m; loadedId = id; lock.unlock()
    }

    /// ONNX Runtime из Contents/Frameworks. Неудачу помним до конца запуска: файл бандла за это
    /// время не появится, а повторный dlopen на каждой диктовке только засорял бы лог.
    private static func loadRuntime() -> OrtRuntime? {
        if let runtime { return runtime }
        if runtimeFailed { return nil }
        let path = (Bundle.main.privateFrameworksPath ?? "") + "/libonnxruntime.dylib"
        do { runtime = try OrtRuntime(libraryPath: path) }
        catch { runtimeFailed = true; kbLog("gigaam: ONNX Runtime не загрузился (\(error))") }
        return runtime
    }

    /// Расшифровка 16 кГц mono Float32. nil — отказ движка, пустая строка — человек промолчал
    /// (то же различие, что у Parakeet, см. ParakeetEngine.transcribe). Язык не передаём: модель
    /// только русская, выбирать ей нечего.
    func transcribe(samples: [Float]) async -> String? {
        await withCheckedContinuation { c in
            queue.async {
                guard let m = self.model else { return c.resume(returning: nil) }
                do { c.resume(returning: try m.transcribe(samples)) }
                catch { kbLog("gigaam: ошибка транскрипции: \(error)"); c.resume(returning: nil) }
            }
        }
    }

    /// Выгрузить из памяти, не трогая файлы. Встаёт в очередь после идущей работы, поэтому
    /// посреди загрузки или распознавания модель из-под ног не уйдёт.
    func unload() {
        queue.async {
            guard self.model != nil else { return }
            self.setModel(nil, nil)
            kbLog("gigaam: модель выгружена")
        }
    }

    /// Скачать вариант — ЯВНОЕ действие пользователя (кнопка в настройках). Файлы по очереди во
    /// временную папку, у каждого сверяем размер и SHA-256, и только целый набор переезжает на
    /// место. Половина модели на диске выглядела бы установленной для `isInstalled`.
    func download(_ id: String, progress: @escaping (Double) -> Void) async -> Bool {
        guard let v = Self.variant(id) else { return false }
        let files = v.models + [v.vocab]
        let total = Double(files.reduce(0) { $0 + $1.bytes })
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gigaam-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { return false }
        var done = 0.0
        for f in files {
            guard let url = URL(string: "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/\(Self.pinnedRevision)/\(f.name)")
            else { return false }
            let dest = tmp.appendingPathComponent(f.name)
            let before = done
            guard await TarballDownloader.download(url, to: dest, progress: { p in progress((before + p * Double(f.bytes)) / total) })
            else { kbLog("gigaam: \(f.name) не скачался"); return false }
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
            guard size == f.bytes, ModelDownloader.sha256(ofFileAt: dest) == f.sha256 else {
                kbLog("model integrity FAIL gigaam \(f.name): размер или хеш не сошёлся — набор отклонён")
                return false
            }
            done += Double(f.bytes)
        }
        let final = Self.dir(id)
        do {
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: tmp, to: final)
        } catch {
            kbLog("gigaam: установка \(id) не удалась: \(error)")
            return false
        }
        kbLog("model downloaded+verified: \(id)")
        return true
    }

    /// Удалить вариант с диска. Загруженную копию сначала отпускаем, удаление — в фоне (крупный
    /// файл, main-поток не морозим: см. deleteModel в ParakeetEngine). completion — на main.
    func delete(_ id: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            if self.loadedId == id { self.setModel(nil, nil) }
            do { try FileManager.default.removeItem(at: Self.dir(id)); kbLog("model deleted: \(id)") }
            catch { kbLog("gigaam: удаление \(id): \(error)") }
            let ok = !FileManager.default.fileExists(atPath: Self.dir(id).path)   // нечего было удалять — тоже успех
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

#else
/// Intel-заглушка: GigaAM включена только для Apple Silicon (решение автора 25.10.2026; почему —
/// в шапке GigaAMCore.swift). Интерфейс тот же, чтобы остальной код собирался без #if, как у
/// ParakeetEngine: пустой каталог и modelInstalled=false сводят всё к whisper-пути.
final class GigaAMEngine {
    struct Variant { let id: String; let name: String; let size: String; let note: String; let help: String }
    static let shared = GigaAMEngine()
    static let catalog: [Variant] = []
    static func isInstalled(_ id: String) -> Bool { false }
    static var modelInstalled: Bool { false }
    var ready: Bool { false }
    func loadIfNeeded() async -> Bool { false }
    func transcribe(samples: [Float]) async -> String? { nil }
    func unload() {}
    func download(_ id: String, progress: @escaping (Double) -> Void) async -> Bool { false }
    func delete(_ id: String, completion: @escaping (Bool) -> Void) { DispatchQueue.main.async { completion(true) } }
}
#endif
