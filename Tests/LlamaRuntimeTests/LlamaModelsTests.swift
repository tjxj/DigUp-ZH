import Foundation
import Testing
import DigUpKit
@testable import LlamaRuntime

@Suite final class LlamaModelsTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-ZH-ModelPaths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    // Sparse files test the download-completeness check without loading a model or allocating model-sized data.
    func sparse(_ name: String, bytes: Int64, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? folder).appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
        return url
    }

    @Test func absentEmptyAndTruncatedTextStayUnavailable() throws {
        #expect(throws: WorkerError.self) { try LlamaModels.locate(in: [folder]) }
        _ = try sparse(ModelFiles.text.name, bytes: 0)
        #expect(throws: WorkerError.self) { try LlamaModels.locate(in: [folder]) }
        _ = try sparse(ModelFiles.text.name, bytes: ModelFiles.text.bytes - 1)
        #expect(throws: WorkerError.self) { try LlamaModels.locate(in: [folder]) }
    }

    @Test func partialVisualProjectorDoesNotLookReady() throws {
        _ = try sparse(ModelFiles.text.name, bytes: ModelFiles.text.bytes)
        #expect(try LlamaModels.locate(in: [folder]).media == nil)
        _ = try sparse(ModelFiles.media.name, bytes: ModelFiles.media.bytes - 1)
        #expect(try LlamaModels.locate(in: [folder]).media == nil)
        _ = try sparse(ModelFiles.media.name, bytes: ModelFiles.media.bytes)
        let located = try LlamaModels.locate(in: [folder])
        #expect(located.text == folder.appendingPathComponent(ModelFiles.text.name))
        #expect(located.media == folder.appendingPathComponent(ModelFiles.media.name))
    }

    @Test func huggingFaceStyleSymlinksUseTheTargetFileSize() throws {
        let blobs = folder.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for (index, file) in ModelFiles.all.enumerated() {
            let blob = try sparse("blob-\(index)", bytes: file.bytes, in: blobs)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(file.name), withDestinationURL: blob)
        }
        #expect(ModelFiles.missing(in: folder).isEmpty)
        #expect(try LlamaModels.locate(in: [folder]).media != nil)
    }

    @Test func searchContinuesPastAnIncompleteDirectory() throws {
        let complete = folder.appendingPathComponent("complete")
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)
        _ = try sparse(ModelFiles.text.name, bytes: 0)
        _ = try sparse(ModelFiles.text.name, bytes: ModelFiles.text.bytes, in: complete)
        #expect(try LlamaModels.locate(in: [folder, complete]).text.deletingLastPathComponent().path == complete.path)
    }
}
