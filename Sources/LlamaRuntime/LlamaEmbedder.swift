import CLlama
import DigUpKit
import Foundation

/// Qwen3-VL-Embedding on llama.cpp. Each input uses its own causal context.
/// Pool the final assistant-prefix token, then L2-normalize the 2048 values.
/// Media goes through mtmd's complete M-RoPE + DeepStack path.
public final class LlamaEmbedder: Embedder {
    public static let budgets = [70, 140, 280, 560, 1120]
    public static let vectorVersion = 2
    public static let buildTag = LLAMA_BUILD_TAG
    public static let modelInfo = WorkerInfo(model: "Qwen/Qwen3-VL-Embedding-2B", revision: LlamaModels.revision,
                                             runtime: "llama.cpp-qwen-zh-vectors\(vectorVersion)",
                                             dtype: "text-q4_k_m+mmproj-f16", dim: 2048, textOnly: false,
                                             loadSeconds: nil)
    public private(set) var info: WorkerInfo
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private var batch: OpaquePointer?
    private let vocab: OpaquePointer?
    private let maxTokens: Int
    private static let batchSize = 2048

    public init(models: LlamaModels, textOnly: Bool, log: URL? = nil) throws {
        let started = Date()
        LlamaLog.shared.send(to: log)
        _ = Self.backend
        guard textOnly || models.media != nil else {
            throw WorkerError.notFound("图片模型尚未就绪：\(LlamaModels.mediaFile)")
        }
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(models.text.path, modelParams) else {
            throw WorkerError.failed("无法加载模型：\(models.text.lastPathComponent)")
        }
        let maxTokens = textOnly ? 2048 : 8192
        var params = llama_context_default_params()
        params.n_ctx = UInt32(maxTokens)
        params.n_batch = UInt32(Self.batchSize)
        params.n_ubatch = 512
        params.n_seq_max = 1
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_LAST
        params.attention_type = LLAMA_ATTENTION_TYPE_CAUSAL
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw WorkerError.failed("无法初始化模型")
        }
        var media: OpaquePointer?
        if let mediaFile = models.media, !textOnly {
            var mediaParams = mtmd_context_params_default()
            mediaParams.use_gpu = true
            mediaParams.print_timings = false
            mediaParams.warmup = true
            mediaParams.image_min_tokens = 64
            mediaParams.image_max_tokens = 1120
            media = mtmd_init_from_file(mediaFile.path, model, mediaParams)
            if media == nil {
                llama_free(context)
                llama_model_free(model)
                throw WorkerError.failed("无法加载图片模型：\(mediaFile.lastPathComponent)")
            }
        }
        self.model = model
        self.context = context
        self.media = media
        batch = llama_batch_ext_init(context)
        vocab = llama_model_get_vocab(model)
        self.maxTokens = maxTokens
        let known = Self.modelInfo
        info = WorkerInfo(model: known.model, revision: known.revision, runtime: known.runtime, dtype: known.dtype,
                          dim: Int(llama_model_n_embd_out(model)), textOnly: textOnly, loadSeconds: nil)
        do {
            guard info.dim == 2048 else { throw WorkerError.failed("模型维度不匹配，请使用指定的 Qwen 模型") }
            _ = try embedTexts([Prompts.query("准备搜索")])
        } catch {
            close()
            throw error
        }
        let seconds = (Date().timeIntervalSince(started) * 100).rounded() / 100
        info = WorkerInfo(model: info.model, revision: info.revision, runtime: info.runtime, dtype: info.dtype,
                          dim: info.dim, textOnly: textOnly, loadSeconds: seconds)
        LlamaLog.shared.line("Qwen ready in \(seconds) s (\(textOnly ? "text-only" : "text+vision"), \(Self.buildTag))")
    }

    deinit { close() }
    public func close() {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (batch, media, context, model) = (nil, nil, nil, nil)
    }

    public func embedTexts(_ texts: [String]) throws -> [[Float]] {
        guard context != nil else { throw WorkerError.failed("模型已关闭") }
        return try texts.map { text in
            reset()
            let tokens = try tokenize(text)
            try decode(tokens, at: 0, output: true)
            return try vector()
        }
    }

    public func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        guard media != nil else { throw WorkerError.failed("当前只加载了文字模型") }
        guard Self.budgets.contains(budget) else { throw WorkerError.failed("无效的图片精度") }
        return paths.map { path in
            do { return Embedding(vector: try embedImage(path, budget: budget), error: nil) }
            catch { return Embedding(vector: nil, error: String("\(error)".prefix(300))) }
        }
    }

    public func embedAudio(_ paths: [String]) throws -> [Embedding] {
        paths.map { _ in Embedding(vector: nil, error: "Qwen3-VL-Embedding 不支持音频内容；视频仅检索画面。") }
    }

    private func reset() {
        llama_batch_ext_clear(batch)
        if let memory = llama_get_memory(context) { llama_memory_clear(memory, true) }
    }

    /// Do not silently truncate: readers split long passages before this layer.
    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), false, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), false, true)
        }
        guard count > 0 else { throw WorkerError.failed("无法读取输入文字") }
        guard count <= maxTokens else { throw WorkerError.failed("文字过长，请缩短搜索内容或拆分文档段落") }
        return Array(tokens.prefix(Int(count)))
    }

    private func decode(_ tokens: [llama_token], at start: llama_pos, output: Bool) throws {
        for offset in stride(from: 0, to: tokens.count, by: Self.batchSize) {
            llama_batch_ext_clear(batch)
            let end = min(tokens.count, offset + Self.batchSize)
            for i in offset..<end {
                let index = llama_batch_ext_add_token(batch, 0, tokens[i])
                var position = start + llama_pos(i)
                guard index >= 0, llama_batch_ext_set_pos(batch, index, &position) else {
                    throw WorkerError.failed("无法准备文字输入")
                }
                if output && i == tokens.count - 1 { _ = llama_batch_ext_set_output_embd(batch, index, true) }
            }
            let status = llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch)
            guard status == 0 else { throw WorkerError.failed("模型计算失败（\(status)）") }
        }
    }

    private func embedImage(_ path: String, budget: Int) throws -> [Float] {
        let wrapper = mtmd_helper_bitmap_init_from_file(media, path, false, mtmd_helper_init_opt_default())
        if let video = wrapper.video_ctx {
            if let bitmap = wrapper.bitmap { mtmd_bitmap_free(bitmap) }
            mtmd_helper_video_free(video)
            throw LlamaError("请先将视频读取为画面")
        }
        guard let original = wrapper.bitmap else { throw LlamaError("无法读取图片：\(path)") }
        defer { mtmd_bitmap_free(original) }
        guard !mtmd_bitmap_is_audio(original) else { throw LlamaError("不支持音频输入") }
        let width = Int(mtmd_bitmap_get_nx(original)), height = Int(mtmd_bitmap_get_ny(original))
        let scale = min(1, sqrt(Double(budget * 32 * 32) / Double(max(1, width * height))))
        let targetW = max(32, Int(Double(width) * scale / 32) * 32)
        let targetH = max(32, Int(Double(height) * scale / 32) * 32)
        let pixels = ImageSizing.resizeBicubic(mtmd_bitmap_get_data(original), width: width, height: height,
                                              toWidth: targetW, toHeight: targetH)
        guard let bitmap = mtmd_bitmap_init(UInt32(targetW), UInt32(targetH), pixels) else {
            throw LlamaError("无法准备图片")
        }
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let prompt = Prompts.framed(String(cString: mtmd_default_marker()))
        let status = prompt.withCString { pointer in
            var input = mtmd_input_text(text: pointer, text_len: strlen(pointer), add_special: false, parse_special: true)
            return mtmd_tokenize(media, chunks, &input, &bitmaps, 1)
        }
        guard status == 0 else { throw LlamaError("图片输入失败（\(status)）") }
        guard mtmd_helper_get_n_tokens(chunks) <= maxTokens else { throw LlamaError("图片内容过长") }
        reset()
        var position: llama_pos = 0
        let result = mtmd_helper_eval_chunks(media, context, chunks, 0, 0, Int32(Self.batchSize), true, &position)
        guard result == 0 else { throw LlamaError("图片计算失败（\(result)）") }
        return try vector()
    }

    private func vector() throws -> [Float] {
        guard let pooled = llama_get_embeddings_seq(context, 0) else {
            throw WorkerError.failed("模型未返回向量")
        }
        var values = Array(UnsafeBufferPointer(start: pooled, count: 2048))
        guard values.allSatisfy({ $0.isFinite }) else { throw WorkerError.failed("模型返回无效数值") }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0 else { throw WorkerError.failed("模型返回空向量") }
        for i in values.indices { values[i] /= Float(norm) }
        return values
    }

    private static let backend: Void = {
        llama_log_set(LlamaLog.callback, LlamaLog.userData)
        mtmd_helper_log_set(LlamaLog.callback, LlamaLog.userData)
        llama_backend_init()
    }()
}

/// A problem with one input (it gets no vector; its neighbours go on).
struct LlamaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// llama.cpp's log is process-wide: warnings and errors go to one file (or stderr), the rest is dropped (it logs a lot
/// at load time).
final class LlamaLog: @unchecked Sendable {
    static let shared = LlamaLog()
    nonisolated(unsafe) static let userData = Unmanaged.passUnretained(shared).toOpaque()
    nonisolated(unsafe) static let callback: ggml_log_callback = { level, text, userData in
        guard let text, let userData else { return }
        Unmanaged<LlamaLog>.fromOpaque(userData).takeUnretainedValue().write(level, String(cString: text))
    }

    private let lock = NSLock()
    private var file: FileHandle?             // nil: stderr
    private var level = GGML_LOG_LEVEL_INFO   // CONT continues the previous message, at its level

    func send(to url: URL?) {
        lock.withLock {
            try? file?.close()
            file = nil
            guard let url else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            file = try? FileHandle(forWritingTo: url)
            file?.seekToEndOfFile()
        }
    }

    /// One of our own lines.
    func line(_ message: String) {
        lock.withLock { (file ?? .standardError).write(Data("[llama.cpp worker] \(message)\n".utf8)) }
    }

    private func write(_ level: ggml_log_level, _ text: String) {
        lock.withLock {
            if level != GGML_LOG_LEVEL_CONT { self.level = level }
            guard self.level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
            (file ?? .standardError).write(Data(text.utf8))
        }
    }
}
