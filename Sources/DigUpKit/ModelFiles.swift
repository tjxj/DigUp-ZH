import CryptoKit
import Foundation

/// Qwen3-VL-Embedding-2B: the requested Q4_K_M text weights and matching f16 vision projector,
/// pinned to one DevQuasar conversion revision. Both are required for image and video-frame search.
///
/// The app downloads them on first launch (`ModelDownload`) and the helper loads them (`LlamaModels`); this is what
/// both agree on.
public enum ModelFiles {
    public static let repository = "DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF"
    public static let revision = "6a1b927414664e0e17dd379913e3416a1ae1b48d"

    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String

        /// Hugging Face's address for this file at the pinned revision (it redirects to a CDN that takes HTTP ranges).
        public var url: URL {
            URL(string: "https://huggingface.co/\(ModelFiles.repository)/resolve/\(ModelFiles.revision)/\(name)")!
        }
    }

    /// The text model (about 1.11 GB): all that queries need.
    public static let text = File(name: "Qwen.Qwen3-VL-Embedding-2B.Q4_K_M.gguf", bytes: 1_107_410_528,
                                  sha256: "42a4ebc629ecc6514649e12b1529b857f54900273bb854f853c970fb90edd09d")
    /// The vision projector (about 819 MB). This model has no audio encoder.
    public static let media = File(name: "mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf", bytes: 819_395_136,
                                   sha256: "3f89a7768ffa6606935319f71bf56bb71871249ba549bf1080a0caea7a088613")
    /// In download order.
    public static let all = [text, media]
    public static let totalBytes = all.reduce(0) { $0 + $1.bytes }

    /// Where the app keeps them.
    public static let installed = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DigUp-ZH/Models")

    /// The pinned revision's folder in the Hugging Face cache (`hf download` puts the files there): `$HF_HUB_CACHE`,
    /// `$HF_HOME/hub`, or `~/.cache/huggingface/hub`.
    public static var huggingFaceSnapshot: URL {
        let environment = ProcessInfo.processInfo.environment
        let hub = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        return hub.appendingPathComponent("models--\(repository.replacingOccurrences(of: "/", with: "--"))/snapshots/\(revision)")
    }

    /// `file` in the Hugging Face cache, when it's there at the right size (its checksum is for the caller to check).
    public static func cachedCopy(of file: File) -> URL? {
        let url = huggingFaceSnapshot.appendingPathComponent(file.name).resolvingSymlinksInPath()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size == file.bytes ? url : nil
    }

    /// Files missing or truncated in `folder`. Downloaded and packaged files are also SHA-256 checked before use.
    public static func missing(in folder: URL) -> [File] {
        all.filter {
            let path = folder.appendingPathComponent($0.name).resolvingSymlinksInPath().path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return size != $0.bytes
        }
    }

    /// The SHA-256 of a file as lowercase hex, read in 8 MB pieces.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool { () -> Bool in
                guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
