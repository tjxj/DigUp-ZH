import AppKit
import Foundation
import Testing
@testable import DigUpKit

@Suite final class ChineseSearchTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpChinese-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func add(_ text: String, path: String = "/资料/中文测试.txt", to store: IndexStore, inode: UInt64 = 1) throws {
        let id = try store.insert(Candidate(path: path, kind: .doc, size: Int64(text.utf8.count), mtime: 1,
                                            inode: inode, device: 1))
        try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: text)
    }

    @Test func traditionalChineseAndFullWidthNormalizeTogether() {
        #expect(SearchText.normalized("臺灣財務發票ＡＢＣ－１２３") == "台湾财务发票ABC-123")
        #expect(SearchText.normalized("軟體與資料庫") == "软体与资料库")
    }

    @Test func chineseQueriesDoNotNeedSpaces() throws {
        let store = try IndexStore(directory: folder)
        try add("今天讨论的是个人健康管理系统，接下来准备项目预算。", to: store)
        let search = try Searcher(store: store, loadVectors: false)
        #expect(try search.search("健康管理", queryVector: nil).first?.path == "/资料/中文测试.txt")
        #expect(try search.search("预算", queryVector: nil).count == 1)
        #expect(try search.search("税", queryVector: nil).isEmpty)
        #expect(Searcher.terms("帮我查找健康管理的项目预算").contains("预算"))
    }

    @Test func traditionalAndSimplifiedFindEachOtherAndKeepOriginalExcerpt() throws {
        let store = try IndexStore(directory: folder)
        try add("這份財務報告記錄了發票與年度營業收入。", to: store)
        let search = try Searcher(store: store, loadVectors: false)
        let hits = try search.search("发票", queryVector: nil)
        #expect(hits.count == 1)
        #expect(hits.first?.excerpt?.contains("«發票»") == true)
        #expect(try search.search("財務報告", queryVector: nil).count == 1)
        #expect(try search.text(ofSegment: hits.first?.segmentID ?? -1) == "這份財務報告記錄了發票與年度營業收入。")
    }

    @Test func chineseFileAndFolderNamesAreSearchableAfterRename() throws {
        let store = try IndexStore(directory: folder)
        let id = try store.insert(Candidate(path: "/财务资料/年度报销发票.pdf", kind: .pdf, size: 1, mtime: 1,
                                            inode: 1, device: 1))
        let search = try Searcher(store: store, loadVectors: false)
        #expect(try search.search("报销", queryVector: nil).count == 1)
        #expect(try search.search("財務", queryVector: nil).count == 1)
        try store.move(id, to: "/研究资料/機器學習筆記.pdf")
        #expect(try search.search("机器学习", queryVector: nil).first?.path == "/研究资料/機器學習筆記.pdf")
        #expect(try search.search("报销", queryVector: nil).isEmpty)
    }

    @Test func mixedTextKeepsModelNamesAndExactNumberedIdentifiers() throws {
        let store = try IndexStore(directory: folder)
        try add("模型Qwen3-VL-Embedding-2B已下载，合同编号HT-2026-001。", path: "/资料/正确.txt", to: store)
        try add("模型Qwen3-VL-Embedding-8B已下载，合同编号HT-2026-002。", path: "/资料/其他.txt", to: store, inode: 2)
        let search = try Searcher(store: store, loadVectors: false)
        #expect(try search.search("ＨＴ－２０２６－００１", queryVector: nil).map(\.path) == ["/资料/正确.txt"])
        #expect(try search.search("Qwen3-VL-Embedding-2B", queryVector: nil).map(\.path) == ["/资料/正确.txt"])
        #expect(try search.search("HT-2026-099", queryVector: nil).isEmpty)
        #expect(try search.search("合同编号HT-2026-001", queryVector: nil).first?.path == "/资料/正确.txt")
    }

    @Test func chineseMatchingAndSnippetsUseOriginalBoundaries() {
        let text = "這份發票編號ＡＢＣ１２３已核對"
        #expect(SearchText.matches(of: "发票", in: text).map { String(text[$0]) } == ["發票"])
        #expect(SearchText.matches(of: "ABC123", in: text).map { String(text[$0]) } == ["ＡＢＣ１２３"])
        #expect(SearchText.matches(of: "BC12", in: text).isEmpty)
        let long = String(repeating: "前文", count: 300) + "发票" + String(repeating: "后文", count: 300)
        let snippet = SearchText.snippet(long, terms: ["发票"])
        #expect(snippet?.contains("«发票»") == true)
        #expect((snippet?.count ?? 1000) < 200)
        #expect(Landmark.find(page: 2, texts: ["首页", "项目预算和發票"], words: ["发票"]) == "發票")
    }

    @Test func contextDependentChineseConversionKeepsHighlightsConsistent() {
        let text = "本文件受到著作權保護。"
        #expect(SearchText.matches(of: "著作权", in: text).map { String(text[$0]) } == ["著作權"])
        #expect(SearchText.snippet(text, terms: ["著作权"])?.contains("«著作權»") == true)
    }

    @Test func chineseWordsWrappedAcrossPDFLinesKeepOriginalHighlights() throws {
        let text = "這份項目預\n算已通過。"
        #expect(SearchText.matches(of: "预算", in: text).map { String(text[$0]) } == ["預\n算"])
        let store = try IndexStore(directory: folder)
        try add(text, to: store)
        let hit = try Searcher(store: store, loadVectors: false).search("预算", queryVector: nil).first
        #expect(hit?.excerpt?.contains("«預 算»") == true)
    }

    @MainActor @Test func chineseOCRReadsMixedSimplifiedTraditionalAndInvoiceNumber() throws {
        let image = NSImage(size: NSSize(width: 1400, height: 280))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1400, height: 280).fill()
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black]
        ("财务报销 发票编号 HT-2026-001" as NSString).draw(at: NSPoint(x: 40, y: 160), withAttributes: style)
        ("專案預算與年度營業收入" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: style)
        image.unlockFocus()
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let recognized = SearchText.normalized(OCR.text(in: bitmap))
        #expect(recognized.contains("财务报销"))
        #expect(recognized.contains("HT-2026-001"))
        #expect(recognized.contains("年度营业收入"))
    }

    @Test func pastedQueryOperatorsAndPunctuationCannotBreakSearch() throws {
        let store = try IndexStore(directory: folder)
        try add("项目预算已提交。", to: store)
        let search = try Searcher(store: store, loadVectors: false)
        for query in ["\"预算\" OR *", "NEAR(预算, \"报销\")", "预算'; DROP TABLE files;--", "😀？！", "\u{0000}预算"] {
            _ = try search.search(query, queryVector: nil)
        }
        #expect(try search.search("预算", queryVector: nil).count == 1)
    }

    @Test func noSpaceChineseChunksPreserveTermsAcrossEveryBoundary() {
        let text = String(repeating: "这是一份中文资料", count: 100) + "边界关键字" + String(repeating: "继续阅读", count: 100)
        let chunks = DocExtractor.chunks(text, size: 100, overlap: 20, limit: 100)
        let chars = Array(text)
        for offset in stride(from: 0, to: chars.count - 6, by: 3) {
            let phrase = String(chars[offset..<(offset + 6)])
            #expect(chunks.contains(where: { $0.contains(phrase) }))
        }
        #expect(chunks.last?.hasSuffix(String(text.suffix(20))) == true)
        #expect(chunks.allSatisfy { $0.count <= 100 })
    }

    @Test func longChineseLineAndNotebookCellKeepTheirTail() {
        let text = String(repeating: "中文长段落没有换行。", count: 600) + "末尾独有关键字"
        let pieces = CodeExtractor.lines(text, size: 1800)
        #expect(pieces.contains(where: { $0.text.contains("末尾独有关键字") }))
        #expect(pieces.allSatisfy { $0.first == 1 && $0.last == 1 })
        #expect(CodeExtractor.cells([text]).contains(where: { $0.text.contains("末尾独有关键字") }))
    }

    @Test func schemaFiveRebuildsChineseTextAndNamesFromOriginals() throws {
        let db = try Database(path: folder.appendingPathComponent("index.sqlite").path)
        try db.execute("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                size INTEGER NOT NULL, mtime REAL NOT NULL, inode INTEGER NOT NULL, device INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', detail TEXT, info TEXT, indexed_at REAL);
            CREATE TABLE segments(id INTEGER PRIMARY KEY, file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, modality TEXT NOT NULL, loc REAL, loc_end REAL, excerpt TEXT, vec BLOB);
            CREATE VIRTUAL TABLE fts USING fts5(name, body, original UNINDEXED,
                tokenize = 'porter unicode61 remove_diacritics 2');
            INSERT INTO files VALUES(1, '/資料/年度財務報告.txt', 'doc', 1, 1, 1, 1, 'done', NULL, NULL, 1);
            INSERT INTO segments VALUES(1, 1, 'name', 'none', NULL, NULL, NULL, NULL);
            INSERT INTO segments VALUES(2, 1, 'chunk', 'none', 1, NULL, NULL, NULL);
            INSERT INTO fts(rowid, name, body) VALUES(1, '年度財務報告.txt', '資料');
            INSERT INTO fts(rowid, name, body) VALUES(2, '', '發票報銷金額已核對');
            PRAGMA user_version = 5;
            """)
        let store = try IndexStore(directory: folder)
        let search = try Searcher(store: store, loadVectors: false)
        #expect(try search.search("报销", queryVector: nil).count == 1)
        #expect(try search.search("财务", queryVector: nil).count == 1)
        #expect(try search.text(ofSegment: 2) == "發票報銷金額已核對")
    }
}
