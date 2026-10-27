import Foundation

/// Модель подсказок продолжения: Gemma 4 E2B instruct, GGUF Q4_K_M (docs/inline-prediction.md).
///
/// Правила те же, что у `ModelDownloader`: сеть только по кнопке, URL пиннится на неизменяемую
/// commit-ревизию, после скачивания сверяется SHA-256 (тем же `ModelDownloader.sha256`), при
/// несовпадении файл удаляется и не ставится. Отдельный класс, а не запись в каталоге whisper:
/// тот каталог знает имена `ggml-<name>.bin` и путь `VoiceController.modelPath`, а этот файл не
/// модель диктовки и в списке моделей диктовки ему не место.
final class PredictionModel: NSObject, URLSessionDownloadDelegate {
    static let shared = PredictionModel()

    /// `unsloth/gemma-4-E2B-it-GGUF`, ревизия от 17.07.2026. Хеш и размер сверены с LFS-метаданными
    /// HF на этой ревизии (paths-info, X-Linked-ETag).
    static let repo = "unsloth/gemma-4-E2B-it-GGUF"
    static let revision = "0314792d7f1f7e229411f620751375812bb9faf2"
    static let fileName = "gemma-4-E2B-it-Q4_K_M.gguf"
    static let sha256 = "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8"
    /// В EN-единицах, локализуется на показе через L10n.size().
    static let size = "3.1 GB"

    static var url: URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")
    }
    static var path: String {
        VoiceController.modelsDir.appendingPathComponent(fileName).path
    }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.path) }
    var isDownloading: Bool { task != nil }

    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Bool) -> Void)?

    func download(progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
        guard task == nil, let url = Self.url else { done(false); return }
        onProgress = progress
        onDone = done
        kbLog("подсказки: загрузка модели с HuggingFace")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancel() { task?.cancel(); task = nil }

    func delete(completion: @escaping (Bool) -> Void) {
        LLMRuntime.shared.unload()
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            if FileManager.default.fileExists(atPath: Self.path) {
                do { try FileManager.default.removeItem(atPath: Self.path); kbLog("подсказки: модель удалена") }
                catch { ok = false; kbLog("подсказки: модель не удалилась: \(error)") }
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private func finish(_ ok: Bool) {
        task = nil
        DispatchQueue.main.async { self.onDone?(ok) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Ответ с ошибкой (404, 5xx) URLSession тоже кладёт в файл: без проверки статуса мы бы
        // хешировали страницу ошибки. Хеш её всё равно отверг бы, но лог должен называть причину.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            kbLog("подсказки: модель не скачалась (HTTP \(http.statusCode))")
            finish(false); return
        }
        guard ModelDownloader.sha256(ofFileAt: location) == Self.sha256 else {
            kbLog("подсказки: integrity FAIL — хеш модели не сошёлся, файл отклонён")
            try? FileManager.default.removeItem(at: location)
            finish(false); return
        }
        let dest = URL(fileURLWithPath: Self.path)
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        kbLog(ok ? "подсказки: модель скачана и проверена" : "подсказки: модель не встала на место")
        finish(ok)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        kbLog("подсказки: модель не скачалась (\(error.localizedDescription))")
        finish(false)
    }
}
