import Foundation

/// Локальная языковая модель подсказок через libkeyboop_llm.dylib (docs/inline-prediction.md).
///
/// Почему dlopen, а не линковка: внутри dylib своя копия ggml из llama.cpp, а в самом бинаре
/// статически сидит ggml из whisper.cpp. Библиотека экспортирует только `kb_llm_*`, всё остальное
/// в ней скрыто, и `llama.h` в Swift не попадает вовсе — bridging-заголовок whisper не меняется.
/// Той же дорогой ходит ONNX Runtime у GigaAM.
///
/// Все вызовы модели идут через одну последовательную очередь: хэндл шима не потокобезопасен.
final class LLMRuntime {
    static let shared = LLMRuntime()

    /// Отмена генерации. Флаг читает C-цикл перед каждым токеном.
    final class Cancel {
        fileprivate let flag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        init() { flag.pointee = 0 }
        deinit { flag.deallocate() }
        func cancel() { flag.pointee = 1 }
        var isCancelled: Bool { flag.pointee != 0 }
    }

    private typealias AbiFn = @convention(c) () -> Int32
    private typealias OpenFn = @convention(c) (UnsafePointer<CChar>, Int32, Int32, Int32) -> OpaquePointer?
    private typealias CompleteFn = @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32,
                                                   UnsafePointer<Int32>?, UnsafeMutablePointer<CChar>, Int32) -> Int32
    private typealias CloseFn = @convention(c) (OpaquePointer) -> Void

    private struct Lib { let open: OpenFn; let complete: CompleteFn; let close: CloseFn }

    private static let abiVersion: Int32 = 1
    private static let contextTokens: Int32 = 2048

    private let queue = DispatchQueue(label: "keyboop.llm", qos: .userInitiated)
    private var lib: Lib?
    private var libFailed = false
    private var handle: OpaquePointer?
    private var loadFailed = false

    /// Есть ли движок в этой сборке. Сборка без llama.cpp честно говорит об этом в настройках.
    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: libraryPath)
    }
    private static var libraryPath: String {
        (Bundle.main.privateFrameworksPath ?? "") + "/libkeyboop_llm.dylib"
    }

    /// Продолжение промпта. `done` зовётся на main: nil — нечего показывать (нет движка, модели,
    /// отмена или ошибка), иначе сырой ответ модели.
    func complete(_ prompt: String, maxTokens: Int, cancel: Cancel, done: @escaping (String?) -> Void) {
        queue.async {
            let out = self.run(prompt, maxTokens: maxTokens, cancel: cancel)
            DispatchQueue.main.async { done(cancel.isCancelled ? nil : out) }
        }
    }

    /// Выгрузить модель из памяти (выключили функцию, удалили модель).
    func unload() {
        queue.async {
            if let h = self.handle, let lib = self.lib { lib.close(h) }
            self.handle = nil
            self.loadFailed = false
        }
    }

    private func run(_ prompt: String, maxTokens: Int, cancel: Cancel) -> String? {
        guard !cancel.isCancelled, let h = loadedHandle(), let lib else { return nil }
        let cap = 1024
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        defer { buf.deallocate() }
        let n = prompt.withCString { lib.complete(h, $0, Int32(maxTokens), UnsafePointer(cancel.flag), buf, Int32(cap)) }
        guard n >= 0 else { kbLog("подсказки: модель вернула ошибку \(n)"); return nil }
        return String(cString: buf)
    }

    private func loadedHandle() -> OpaquePointer? {
        if let handle { return handle }
        guard !loadFailed, let lib = loadLibrary() else { return nil }
        let path = PredictionModel.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Apple Silicon: все слои в Metal. Intel: Metal-бэкенда в x86-срезе нет, считаем на CPU.
        #if arch(arm64)
        let gpuLayers: Int32 = -1
        #else
        let gpuLayers: Int32 = 0
        #endif
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        let t0 = Date()
        handle = path.withCString { lib.open($0, Self.contextTokens, gpuLayers, threads) }
        if handle == nil {
            loadFailed = true   // битый файл не станет целым до перезапуска или повторного скачивания
            kbLog("подсказки: модель не загрузилась")
        } else {
            kbLog("подсказки: модель загружена за \(String(format: "%.1f", Date().timeIntervalSince(t0))) с")
        }
        return handle
    }

    private func loadLibrary() -> Lib? {
        if let lib { return lib }
        if libFailed { return nil }
        libFailed = true
        guard let h = dlopen(Self.libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            kbLog("подсказки: движок не загрузился (\(dlerror().map { String(cString: $0) } ?? "нет файла"))")
            return nil
        }
        guard let abi = dlsym(h, "kb_llm_abi_version"), let o = dlsym(h, "kb_llm_open"),
              let c = dlsym(h, "kb_llm_complete"), let cl = dlsym(h, "kb_llm_close"),
              unsafeBitCast(abi, to: AbiFn.self)() == Self.abiVersion else {
            kbLog("подсказки: движок другой версии, не использую")
            return nil
        }
        libFailed = false
        lib = Lib(open: unsafeBitCast(o, to: OpenFn.self),
                  complete: unsafeBitCast(c, to: CompleteFn.self),
                  close: unsafeBitCast(cl, to: CloseFn.self))
        return lib
    }
}
