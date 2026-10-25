import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
// Только arm64 (см. ниже); вне macOS — чтобы стенд собирался на любой машине.
#if arch(arm64) || !os(macOS)

// GIGAAM V3 E2E НА ONNX RUNTIME (25.10.2026).
//
// Здесь всё, что не зависит от AppKit: загрузка ONNX Runtime, лог-мел признаки, прогон модели и
// жадная расшифровка CTC и RNN-T. Скачивание, каталог и связь с настройками живут в
// `GigaAMEngine.swift`. Файл нарочно без kbLog и без Bundle: так его можно собрать и прогнать на
// эталонных записях вне приложения и сверить побуквенно с официальной PyTorch-моделью.
//
// # Почему ONNX Runtime и почему через dlopen
//
// GigaAM не запускается ни whisper.cpp, ни FluidAudio. Официальный репозиторий документирует
// экспорт в ONNX (`model.to_onnx`), а у ONNX Runtime есть готовая сборка под macOS одним .dylib,
// который просто кладётся в Contents/Frameworks рядом со Sparkle. Только Apple Silicon (решение
// автора 25.10): Intel-сборки ORT кончились на 1.23.2, а в 1.21–1.24 на x86 сломаны int8-модели
// (стенд: пустой текст на AVX-512 VNNI, починено в 1.25). Берём 1.29.1, её минимум macOS 14.0,
// ровно как у arm64-среза приложения.
//
// Библиотеку грузим лениво, при первой диктовке GigaAM, а не линкуем к бинарю: если её нет или
// она не грузится, это значит только «GigaAM недоступна», а не «приложение не запустилось». Ссылка
// на 43 МБ кода ради модели, которую большинство не скачает, не должна быть условием старта.
//
// # Что именно повторяем за оригиналом
//
// Признаки — torchaudio.MelSpectrogram с параметрами из config.json ревизий e2e_ctc / e2e_rnnt:
// 16 кГц, n_fft = win = 320, hop = 160, 64 мел-полосы HTK без нормировки, center=false, окно Ханна
// (периодическое, как torch.hann_window), мощность, затем log(clamp(x, 1e-9, 1e9)). Расшифровка —
// CTCGreedyDecoding и RNNTGreedyDecoding из modeling_gigaam.py той же ревизии (до 10 символов на
// кадр у RNN-T). Длиннее 25 секунд модель не берёт («transcribe ... only up to 25 seconds» в
// README), поэтому длинную запись режем сами, в самом тихом месте.

enum GigaAMError: Error, CustomStringConvertible {
    case runtime(String)
    var description: String { if case .runtime(let s) = self { return s }; return "" }
}

/// ONNX Runtime, загруженный из .dylib. Один на процесс: среда (OrtEnv) по документации тоже одна.
final class OrtRuntime {
    let api: OrtApi
    let env: OpaquePointer
    let allocator: UnsafeMutablePointer<OrtAllocator>

    init(libraryPath: String) throws {
        // RTLD_LOCAL: символы ORT не всплывают в общее пространство и не спорят ни с кем.
        // Дескриптор не закрываем: сессии живут до конца процесса или до выгрузки модели.
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw GigaAMError.runtime("dlopen: " + (dlerror().map { String(cString: $0) } ?? libraryPath))
        }
        guard let sym = dlsym(handle, "OrtGetApiBase") else { throw GigaAMError.runtime("нет OrtGetApiBase") }
        typealias GetApiBase = @convention(c) () -> UnsafePointer<OrtApiBase>?
        guard let base = unsafeBitCast(sym, to: GetApiBase.self)(),
              let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw GigaAMError.runtime("ONNX Runtime не поддерживает API \(ORT_API_VERSION)")
        }
        self.api = api.pointee
        var env: OpaquePointer?
        try Self.check(self.api, self.api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "keyboop", &env))
        var alloc: UnsafeMutablePointer<OrtAllocator>?
        try Self.check(self.api, self.api.GetAllocatorWithDefaultOptions(&alloc))
        guard let env, let alloc else { throw GigaAMError.runtime("ONNX Runtime не создал среду") }
        self.env = env
        self.allocator = alloc
    }

    static func check(_ api: OrtApi, _ status: OpaquePointer?) throws {
        guard let status else { return }
        let msg = api.GetErrorMessage(status).map { String(cString: $0) } ?? "ошибка ONNX Runtime"
        api.ReleaseStatus(status)
        throw GigaAMError.runtime(msg)
    }
    func check(_ status: OpaquePointer?) throws { try Self.check(api, status) }

    /// Тензор, память которого принадлежит ORT: не надо следить, чтобы Swift-массив пережил вызов.
    func tensor<T>(_ values: [T], _ shape: [Int64], _ type: ONNXTensorElementDataType) throws -> OpaquePointer {
        var value: OpaquePointer?
        try check(api.CreateTensorAsOrtValue(allocator, shape, shape.count, type, &value))
        guard let value else { throw GigaAMError.runtime("тензор не создан") }
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(value, &raw))
        values.withUnsafeBytes { src in raw?.copyMemory(from: src.baseAddress!, byteCount: src.count) }
        return value
    }

    /// Float-выход модели: данные и форма. Значение освобождает вызывающий.
    func floats(_ value: OpaquePointer) throws -> (data: [Float], shape: [Int]) {
        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(value, &info))
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var rank = 0
        try check(api.GetDimensionsCount(info, &rank))
        var dims = [Int64](repeating: 0, count: rank)
        try check(api.GetDimensions(info, &dims, rank))
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(value, &raw))
        let shape = dims.map(Int.init)
        let n = shape.reduce(1, *)
        guard let p = raw?.assumingMemoryBound(to: Float.self) else { throw GigaAMError.runtime("пустой выход") }
        return (Array(UnsafeBufferPointer(start: p, count: n)), shape)
    }
}

/// Одна ONNX-модель (CTC целиком или одна из трёх частей RNN-T).
final class OrtModel {
    private let rt: OrtRuntime
    private let session: OpaquePointer

    init(_ rt: OrtRuntime, path: String, threads: Int) throws {
        self.rt = rt
        var opts: OpaquePointer?
        try rt.check(rt.api.CreateSessionOptions(&opts))
        defer { rt.api.ReleaseSessionOptions(opts) }
        try rt.check(rt.api.SetIntraOpNumThreads(opts, Int32(threads)))
        try rt.check(rt.api.SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL))
        // Арена держала бы у себя пик промежуточных буферов самой длинной диктовки до выгрузки.
        try rt.check(rt.api.DisableCpuMemArena(opts))
        var s: OpaquePointer?
        try rt.check(rt.api.CreateSession(rt.env, path, opts, &s))
        guard let s else { throw GigaAMError.runtime("сессия не создана: \(path)") }
        session = s
    }
    deinit { rt.api.ReleaseSession(session) }

    /// Прогон: входы освобождаются здесь, выходы отдаются как float-массивы.
    func run(_ inputs: [(String, OpaquePointer)], _ outputs: [String]) throws -> [(data: [Float], shape: [Int])] {
        defer { inputs.forEach { rt.api.ReleaseValue($0.1) } }
        let inNames = inputs.map { strdup($0.0) }, outNames = outputs.map { strdup($0) }
        defer { (inNames + outNames).forEach { free($0) } }
        var inPtrs = inNames.map { UnsafePointer<CChar>($0) }
        var outPtrs = outNames.map { UnsafePointer<CChar>($0) }
        var inVals: [OpaquePointer?] = inputs.map { $0.1 }
        var outVals = [OpaquePointer?](repeating: nil, count: outputs.count)
        try rt.check(rt.api.Run(session, nil, &inPtrs, &inVals, inputs.count, &outPtrs, outputs.count, &outVals))
        defer { outVals.forEach { rt.api.ReleaseValue($0) } }
        return try outVals.map { v in
            guard let v else { throw GigaAMError.runtime("модель не вернула выход") }
            return try rt.floats(v)
        }
    }
}

/// Лог-мел признаки ровно как у FeatureExtractor из modeling_gigaam.py (параметры — в шапке файла).
/// Без Accelerate: так файл собирается и сверяется с эталоном и вне macOS. ДПФ на 320 точек
/// матрицей: для 20 секунд это ~0.2 млрд умножений, на фоне энкодера незаметно.
enum GigaAMFeatures {
    static let sampleRate = 16_000, nFFT = 320, hop = 160, mels = 64
    private static let bins = nFFT / 2 + 1

    private static let window: [Float] = (0..<nFFT).map { 0.5 - 0.5 * Float(cos(2 * Double.pi * Double($0) / Double(nFFT))) }
    private static let cosT: [Float] = dft(cos)
    private static let sinT: [Float] = dft(sin)
    private static func dft(_ f: (Double) -> Double) -> [Float] {
        var t = [Float](repeating: 0, count: bins * nFFT)
        for k in 0..<bins { for n in 0..<nFFT { t[k * nFFT + n] = Float(f(2 * Double.pi * Double((k * n) % nFFT) / Double(nFFT))) } }
        return t
    }
    /// torchaudio.functional.melscale_fbanks(161, 0, 8000, 64, 16000, norm=None, mel_scale="htk"),
    /// хранится как [mels][bins].
    private static let fbank: [Float] = {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let top = mel(Double(sampleRate) / 2)
        let pts = (0..<(mels + 2)).map { hz(top * Double($0) / Double(mels + 1)) }
        var fb = [Float](repeating: 0, count: mels * bins)
        for b in 0..<bins {
            let f = Double(sampleRate) / 2 * Double(b) / Double(bins - 1)
            for m in 0..<mels {
                let down = (f - pts[m]) / (pts[m + 1] - pts[m])
                let up = (pts[m + 2] - f) / (pts[m + 2] - pts[m + 1])
                fb[m * bins + b] = Float(max(0, min(down, up)))
            }
        }
        return fb
    }()

    /// [64 × кадров] построчно (форма входа модели [1, 64, T]) и число кадров.
    static func compute(_ x: ArraySlice<Float>) -> (data: [Float], frames: Int) {
        guard x.count >= nFFT else { return ([], 0) }
        let frames = (x.count - nFFT) / hop + 1
        var out = [Float](repeating: 0, count: mels * frames)
        var buf = [Float](repeating: 0, count: nFFT), power = [Float](repeating: 0, count: bins)
        let start = x.startIndex
        for t in 0..<frames {
            for n in 0..<nFFT { buf[n] = x[start + t * hop + n] * window[n] }
            for k in 0..<bins {
                var re: Float = 0, im: Float = 0
                let row = k * nFFT
                for n in 0..<nFFT { re += buf[n] * cosT[row + n]; im += buf[n] * sinT[row + n] }
                power[k] = re * re + im * im
            }
            for m in 0..<mels {
                var s: Float = 0
                let row = m * bins
                for k in 0..<bins { s += fbank[row + k] * power[k] }
                out[m * frames + t] = log(min(max(s, 1e-9), 1e9))
            }
        }
        return (out, frames)
    }
}

/// Загруженная модель GigaAM v3 e2e (CTC или RNN-T, fp32 или int8: для кода разницы нет).
final class GigaAMModel {
    enum Kind { case ctc, rnnt }
    /// Модель обучена и документирована на кусках до 25 с; длиннее режем.
    static let maxSeconds = 25.0, minCutSeconds = 15.0
    /// Как max_symbols_per_step в RNNTGreedyDecoding.
    private static let maxSymbolsPerFrame = 10
    private static let encDim = 768, predDim = 320

    private let kind: Kind
    private let rt: OrtRuntime
    private let vocab: [String]
    private let parts: [OrtModel]       // ctc: [модель]; rnnt: [encoder, decoder, joint]
    private var blank: Int { vocab.count - 1 }   // последний токен словаря — <blk>

    /// `models` для RNN-T — пути к encoder, decoder и joint именно в этом порядке.
    init(kind: Kind, runtime: OrtRuntime, vocabPath: String, models: [String], threads: Int) throws {
        self.kind = kind
        rt = runtime
        // Строки словаря «токен id» (формат экспорта onnx-asr); id идут подряд с нуля.
        let text = try String(contentsOfFile: vocabPath, encoding: .utf8)
        vocab = text.split(separator: "\n").map { line in
            line.lastIndex(of: " ").map { String(line[..<$0]) } ?? String(line)
        }
        guard vocab.last == "<blk>", models.count == (kind == .ctc ? 1 : 3) else {
            throw GigaAMError.runtime("неожиданный словарь или набор файлов модели")
        }
        parts = try models.map { try OrtModel(runtime, path: $0, threads: threads) }
    }

    /// 16 кГц mono Float32 → текст. Пустая строка — речи не нашлось.
    func transcribe(_ samples: [Float]) throws -> String {
        try Self.split(samples).map { try transcribeChunk($0) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Куски не длиннее maxSeconds; граница — в самом тихом 20-мс кадре между minCut и max.
    static func split(_ x: [Float]) -> [ArraySlice<Float>] {
        let sr = Double(GigaAMFeatures.sampleRate)
        let maxN = Int(maxSeconds * sr), minN = Int(minCutSeconds * sr), frame = 320
        var out: [ArraySlice<Float>] = [], start = 0
        while x.count - start > maxN {
            var best = start + maxN, bestE = Float.infinity
            var f = start + minN
            while f + frame <= start + maxN {
                var e: Float = 0
                for i in f..<(f + frame) { e += x[i] * x[i] }
                if e < bestE { bestE = e; best = f + frame / 2 }
                f += frame
            }
            out.append(x[start..<best]); start = best
        }
        out.append(x[start...])
        return out
    }

    private func transcribeChunk(_ x: ArraySlice<Float>) throws -> String {
        let (feats, frames) = GigaAMFeatures.compute(x)
        guard frames > 0 else { return "" }
        return detokenize(kind == .ctc ? try ctc(feats, frames) : try rnnt(feats, frames))
    }

    private func features(_ feats: [Float], _ frames: Int, _ names: (String, String)) throws -> [(String, OpaquePointer)] {
        [(names.0, try rt.tensor(feats, [1, Int64(GigaAMFeatures.mels), Int64(frames)], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)),
         (names.1, try rt.tensor([Int64(frames)], [1], ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64))]
    }

    /// CTCGreedyDecoding: argmax по кадру, схлопнуть повторы, выкинуть blank.
    private func ctc(_ feats: [Float], _ frames: Int) throws -> [Int] {
        let out = try parts[0].run(try features(feats, frames, ("features", "feature_lengths")), ["log_probs"])[0]
        let (t, c) = (out.shape[1], out.shape[2])
        var ids: [Int] = [], prev = -1
        for i in 0..<t {
            var best = 0
            for k in 1..<c where out.data[i * c + k] > out.data[i * c + best] { best = k }
            if best != blank && best != prev { ids.append(best) }
            prev = best
        }
        return ids
    }

    /// RNNTGreedyDecoding. Стартовое состояние декодера — нули, а вход — blank: его эмбеддинг
    /// нулевой (padding_idx), то есть ровно то, что делает оригинал при `predict(None, None)`.
    /// Имена h.1/c.1 даёт сам torch.onnx.export, когда вход и выход называются одинаково.
    private func rnnt(_ feats: [Float], _ frames: Int) throws -> [Int] {
        let enc = try parts[0].run(try features(feats, frames, ("audio_signal", "length")), ["encoded"])[0]
        let t = enc.shape[2]
        var h = [Float](repeating: 0, count: Self.predDim), c = h
        func predict(_ token: Int) throws -> (g: [Float], h: [Float], c: [Float]) {
            let o = try parts[1].run([
                ("x", try rt.tensor([Int64(token)], [1, 1], ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)),
                ("h.1", try rt.tensor(h, [1, 1, Int64(Self.predDim)], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)),
                ("c.1", try rt.tensor(c, [1, 1, Int64(Self.predDim)], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)),
            ], ["dec", "h", "c"])
            return (o[0].data, o[1].data, o[2].data)
        }
        var ids: [Int] = []
        var p = try predict(blank)
        var frame = [Float](repeating: 0, count: Self.encDim)
        for i in 0..<t {
            for d in 0..<Self.encDim { frame[d] = enc.data[d * t + i] }   // encoded: [1, 768, T]
            for _ in 0..<Self.maxSymbolsPerFrame {
                let j = try parts[2].run([
                    ("enc", try rt.tensor(frame, [1, Int64(Self.encDim), 1], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)),
                    ("dec", try rt.tensor(p.g, [1, Int64(Self.predDim), 1], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)),
                ], ["joint"])[0].data
                var k = 0
                for v in 1..<j.count where j[v] > j[k] { k = v }
                if k == blank { break }
                ids.append(k)
                h = p.h; c = p.c                      // состояние двигаем только после настоящего токена
                p = try predict(k)
            }
        }
        return ids
    }

    /// SentencePiece без byte-fallback (проверено по tokenizer.model обеих ревизий): склеить куски,
    /// «▁» — это пробел. <unk> оригинал печатал бы как « ⁇ », в диктовке он не нужен.
    private func detokenize(_ ids: [Int]) -> String {
        ids.map { vocab[$0] }.filter { $0 != "<unk>" }.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
#endif
