import Foundation
import Testing
@testable import DigUpKit

@Suite struct SmallLibraryTests {
    @Test func oneFileCanMatchByMeaningWithoutReturningAnUnrelatedQuery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpSmall-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        let id = try store.insert(Candidate(path: "/资料/记录.txt", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
        var vector = [Float](repeating: 0, count: Vectors.dimension)
        vector[0] = 1
        try store.addSegment(file: id, kind: .chunk, modality: .text, text: "番茄与鸡蛋", vector: vector)
        let search = try Searcher(store: store)
        func query(_ cosine: Float) -> [Float] {
            var values = [Float](repeating: 0, count: Vectors.dimension)
            values[0] = cosine
            values[1] = sqrt(1 - cosine * cosine)
            return values
        }
        #expect(try search.search("家常菜", queryVector: query(0.48)).count == 1)
        #expect(try search.search("黑洞蒸发", queryVector: query(0.21)).isEmpty)
        #expect(try search.search("HT-2026-099", queryVector: query(0.48)).isEmpty)
    }

    @Test func repeatedSyncThroughTemporaryPathAliasesNeverDuplicates() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/DigUpAlias-\(UUID())")
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("一份普通的中文资料".utf8).write(to: files.appendingPathComponent("记录.txt"))
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { throw WorkerError.failed("unused") })
        #expect(try indexer.sync([files]).added == 1)
        let alias = files.standardizedFileURL
        #expect(try indexer.sync([alias]).unchanged == 1)
        #expect(try store.files(under: [alias.path]).count == 1)
        store.scope = [alias.path]
        #expect(try store.pendingCount() == 1)
        #expect(try store.prune(keepingUnder: [alias.path]) == 0)
    }
}
