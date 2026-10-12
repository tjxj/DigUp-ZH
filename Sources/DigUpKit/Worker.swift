import Foundation

/// What the embedding runtime reports about its model; part of the index fingerprint.
public struct WorkerInfo: Codable, Sendable {
    public let model: String
    public let revision: String
    public let runtime: String
    public let dtype: String
    public let dim: Int
    public let textOnly: Bool
    public let loadSeconds: Double?

    public init(model: String, revision: String, runtime: String, dtype: String, dim: Int, textOnly: Bool,
                loadSeconds: Double?) {
        self.model = model
        self.revision = revision
        self.runtime = runtime
        self.dtype = dtype
        self.dim = dim
        self.textOnly = textOnly
        self.loadSeconds = loadSeconds
    }

    /// Vectors from different models, revisions, runtimes or precisions must never share an index.
    public var vectorSource: String { "\(model)@\(revision.prefix(7)) \(runtime) \(dtype)" }
}

/// The four calls every embedding runtime answers: the model linked into this process (llama.cpp, `LlamaRuntime`), or
/// the bundled `digup worker` process speaking JSON lines (`EmbeddingWorker`).
/// One thread at a time.
public protocol Embedder: AnyObject {
    var info: WorkerInfo { get }
    func embedTexts(_ texts: [String]) throws -> [[Float]]
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding]
    func embedAudio(_ paths: [String]) throws -> [Embedding]
    /// Frees the model. Safe to call twice.
    func close()
}

/// How to start a worker process that speaks the JSON-lines protocol (see `EmbeddingWorker`).
public struct WorkerConfig: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String] = [:]
    public var log: URL?
    /// The worker process's priority: user-initiated for queries, utility for background indexing.
    public var qos: QualityOfService = .default

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The bundled helper (`digup worker`): Qwen3-VL-Embedding-2B on llama.cpp.
    public static func helper(_ executable: URL) -> WorkerConfig {
        WorkerConfig(executable: executable, arguments: ["worker"])
    }

    /// Kept as a source-compatible failure for callers of the retired Python entry point.
    public static func python(_ folder: URL) throws -> WorkerConfig {
        throw WorkerError.failed("旧版 Python worker 已停用。DigUp-ZH 使用内置 Qwen3-VL-Embedding-2B；请通过 DIGUP_MODELS 指定模型目录。")
    }

    /// A legacy override must never silently switch the model or its vector format.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> WorkerConfig? {
        guard environment["DIGUP_WORKER_DIR"] != nil else { return nil }
        throw WorkerError.failed("DIGUP_WORKER_DIR 已停用，请移除此环境变量。DigUp-ZH 使用内置 Qwen3-VL-Embedding-2B；模型目录可通过 DIGUP_MODELS 指定。")
    }
}

public enum WorkerError: Error, CustomStringConvertible {
    case notFound(String), failed(String), died(String)

    public var description: String {
        switch self {
        case .notFound(let why): "worker not found: \(why)"
        case .failed(let why): "worker error: \(why)"
        case .died(let why): "worker stopped: \(why)"
        }
    }
}

/// One embedding (or why the file couldn't be embedded).
public struct Embedding: Sendable {
    public let vector: [Float]?
    public let error: String?

    public init(vector: [Float]?, error: String?) {
        self.vector = vector
        self.error = error
    }
}

/// Talks to the bundled worker over stdin/stdout, one JSON line each way (see `Sources/digup/WorkerService.swift`).
/// The model lives in that separate process so its memory goes back to the OS when it exits.
public final class EmbeddingWorker: Embedder {
    public private(set) var info = WorkerInfo(model: "", revision: "", runtime: "", dtype: "", dim: Vectors.dimension,
                                              textOnly: false, loadSeconds: nil)   // until the worker reports in
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private let log: URL?

    private struct Request: Encodable {
        let id: Int
        let op: String
        let inputs: [String]?
        let budget: Int?
    }

    private struct Reply: Decodable {
        let id: Int?
        let ok: Bool?
        let ready: Bool?
        let error: String?
        let dim: Int?
        let vectors: String?
        let errors: [String?]?
        let info: WorkerInfo?
    }

    public init(_ config: WorkerConfig, textOnly: Bool) throws {
        process.executableURL = config.executable
        process.qualityOfService = config.qos
        process.arguments = config.arguments + (textOnly ? ["--text-only"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging(config.environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        log = config.log
        if let log = config.log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: log)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        let ready = try readReply()
        guard ready.ready == true, let info = ready.info else {
            throw WorkerError.failed(ready.error ?? "didn't start\(logTail())")
        }
        guard info.dim == Vectors.dimension else {
            close()
            throw WorkerError.failed("模型向量维度不匹配：需要 \(Vectors.dimension)，收到 \(info.dim)。请使用 DigUp-ZH 配套模型。")
        }
        self.info = info
    }

    deinit { close() }

    public func embedTexts(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try send("text", texts, budget: nil).map { $0.vector ?? [] }
    }

    public func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        guard !paths.isEmpty else { return [] }
        return try send("image", paths, budget: budget)
    }

    public func embedAudio(_ paths: [String]) throws -> [Embedding] {
        guard !paths.isEmpty else { return [] }
        return try send("audio", paths, budget: nil)
    }

    public func close() {
        guard process.isRunning else { return }
        if let line = try? JSONEncoder().encode(Request(id: 0, op: "quit", inputs: nil, budget: nil)) {
            try? input.fileHandleForWriting.write(contentsOf: line + [0x0A])
        }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
    }

    private func send(_ op: String, _ inputs: [String], budget: Int?) throws -> [Embedding] {
        let id = nextID
        nextID += 1
        let line = try JSONEncoder().encode(Request(id: id, op: op, inputs: inputs, budget: budget))
        do {
            try input.fileHandleForWriting.write(contentsOf: line + [0x0A])
        } catch {
            throw WorkerError.died("can't write to the worker\(logTail())")
        }
        let reply = try readReply()
        guard reply.id == id else { throw WorkerError.failed("reply out of order") }
        guard reply.ok == true, let encoded = reply.vectors, let data = Data(base64Encoded: encoded) else {
            throw WorkerError.failed(reply.error ?? "no vectors")
        }
        let dim = reply.dim ?? Vectors.dimension
        guard dim == info.dim else { throw WorkerError.failed("模型返回的向量维度与启动时不一致") }
        var floats = [Float](repeating: 0, count: data.count / 4)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        guard floats.count == dim * inputs.count else { throw WorkerError.failed("got \(floats.count) floats") }
        let errors = reply.errors ?? []
        return inputs.indices.map { index in
            let error = index < errors.count ? errors[index] : nil
            return Embedding(vector: error == nil ? Array(floats[(index * dim)..<((index + 1) * dim)]) : nil, error: error)
        }
    }

    private func readReply() throws -> Reply {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(Reply.self, from: line)
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw WorkerError.died("exited\(logTail())") }
            buffer.append(chunk)
        }
    }

    private func logTail() -> String {
        guard let log, let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n  ")
        return tail.isEmpty ? "" : "; worker log (\(log.path)):\n  \(tail)"
    }

    static func modelIsCached(_ model: String) -> Bool {
        if FileManager.default.fileExists(atPath: model) { return true }
        let folder = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let hub = ProcessInfo.processInfo.environment["HF_HUB_CACHE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path
        return FileManager.default.fileExists(atPath: "\(hub)/\(folder)/snapshots")
    }
}
