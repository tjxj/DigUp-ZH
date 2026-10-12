import DigUpKit
import Foundation

/// Locates the pinned Qwen Q4_K_M text model and matching f16 visual projector.
public struct LlamaModels: Sendable {
    public static let repository = ModelFiles.repository
    public static let revision = ModelFiles.revision
    /// The text model: sufficient for text queries.
    public static let textFile = ModelFiles.text.name
    /// The visual projector: required to index images and video frames.
    public static let mediaFile = ModelFiles.media.name

    public let text: URL
    /// Nil while only the text part is there.
    public let media: URL?

    /// The folders to look in, first match wins. `$DIGUP_MODELS` is the app's choice and the only place it looks
    /// then: the developer's Hugging Face cache mustn't hide a download that's missing. Without it (the CLI):
    /// Application Support, then the Hugging Face cache.
    public static var folders: [URL] {
        if let chosen = ProcessInfo.processInfo.environment["DIGUP_MODELS"], !chosen.isEmpty {
            return [URL(fileURLWithPath: chosen)]
        }
        return [ModelFiles.installed, ModelFiles.huggingFaceSnapshot]
    }

    /// The first folder with a complete text file. Partial files remain unavailable until their download finishes.
    /// An explicit directory list also makes this check testable without changing the process environment.
    public static func locate(in directories: [URL]? = nil) throws -> LlamaModels {
        let searched = directories ?? folders
        for folder in searched {
            let missing = ModelFiles.missing(in: folder)
            guard !missing.contains(ModelFiles.text) else { continue }
            let text = folder.appendingPathComponent(textFile)
            let media = folder.appendingPathComponent(mediaFile)
            return LlamaModels(text: text, media: missing.contains(ModelFiles.media) ? nil : media)
        }
        throw WorkerError.notFound("未找到完整的 \(textFile)，已检查：" + searched.map(\.path).joined(separator: "、")
            + "。请使用离线完整安装包，或下载配套模型：hf download \(repository) \(textFile) \(mediaFile) --revision \(revision)")
    }

    /// Both files are there, so indexing can run (checked without loading anything).
    public static var complete: Bool {
        (try? locate())?.media != nil
    }
}
