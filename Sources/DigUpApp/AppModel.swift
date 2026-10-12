import AppKit
import Observation

/// State the menubar, the panel and the windows share. Engine updates arrive on the main thread.
@Observable
final class AppModel {
    var status = EngineStatus()
    var settings: AppSettings
    var hotkey: KeyCombo?
    let download: ModelDownload
    /// A newer DigUp the daily check found ("0.6.1"), until you open it (`Updates`).
    var updateAvailable: String?

    init(settings: AppSettings, download: ModelDownload) {
        self.settings = settings
        self.download = download
    }

    var hasFolders: Bool { !settings.roots.isEmpty }
    /// Code search is on (there are code folders).
    var hasCode: Bool { !settings.codeRoots.isEmpty }

    /// One line for the menu and the windows: what the index is doing.
    var statusLine: String {
        let status = self.status
        guard hasFolders else { return "尚未选择文件夹" }
        switch status.activity {
        case .starting: return "正在启动…"
        case .failed(let problem): return "⚠︎ \(problem)"
        case .syncing: return "正在检查文件夹…"
        case .indexing(let done, let total):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            return "正在建立索引 \(percent)% · \(done.formatted()) / \(total.formatted())"
        case .finishing(let done, let total, let files):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            let which = files > 0 ? "\(files.formatted()) 个长文档" : "长文档"
            return "继续读取\(which) · \(percent)%"
        case .idle:
            if let line = downloadLine { return line }
            if let code = status.code.indexing, code.total > 0 {
                let percent = Int((Double(code.done) / Double(code.total) * 100).rounded(.down))
                return "正在处理代码 \(percent)% · \(code.done.formatted()) / \(code.total.formatted())"
            }
            let waiting = "\(status.pending.formatted()) 个文件待处理"
            if status.pending > 0, status.paused { return "已暂停 · \(waiting)" }
            if status.pending > 0, let reason = status.waitingFor { return "\(waiting) · \(reason)" }
            if status.pending > 0 { return "\(waiting)" }
            if status.unfinished > 0 {
                let rest = "\(status.unfinished.formatted()) 个长文档尚未读完"
                if status.paused { return "已暂停 · \(rest)" }
                if let reason = status.waitingFor { return "\(rest) · \(reason)" }
            }
            return "\(status.searchable.formatted()) 个文件已可搜索"
                + (status.paused ? " · 已暂停" : "")
        }
    }

    /// While the model isn't there, how its download goes.
    private var downloadLine: String? {
        switch download.phase {
        case .ready: nil
        case .downloading: "正在下载模型 · \(Int(download.fraction * 100))%"
        case .verifying: "正在校验模型…"
        case .retrying: "下载模型：等待网络恢复"
        case .failed: "⚠︎ 模型下载已停止"
        case .needed: status.pending > 0 ? "模型尚未下载" : nil
        }
    }

    /// 0…1 for the menubar ring and progress bars: the model download, then an indexing pass or the rest of long files.
    var progress: Double? {
        if download.isActive { return download.fraction }
        switch status.activity {
        case .indexing(let done, let total) where total > 0: return Double(done) / Double(total)
        case .finishing(let done, let total, _) where total > 0: return Double(done) / Double(total)
        case .idle:
            guard let code = status.code.indexing, code.total > 0 else { return nil }
            return Double(code.done) / Double(code.total)
        default: return nil
        }
    }

    /// One line about the code index, for Settings → Code: "812 code files indexed", "Indexing code 42%…".
    var codeStatusLine: String {
        let code = status.code
        guard hasCode else { return "代码搜索尚未开启" }
        if !download.isReady { return "模型下载完成后开始读取代码" }
        if let indexing = code.indexing, indexing.total > 0 {
            let percent = Int((Double(indexing.done) / Double(indexing.total) * 100).rounded(.down))
            return "正在处理代码 \(percent)% · \(indexing.done.formatted()) / \(indexing.total.formatted())"
        }
        let waiting = code.pending > 0 ? " · \(code.pending.formatted()) 个待处理" : ""
        if code.pending > 0, status.paused { return "已暂停 · \(code.pending.formatted()) 个代码文件待处理" }
        if code.pending > 0, let reason = status.waitingFor { return "\(code.pending.formatted()) 个代码文件待处理 · \(reason)" }
        return "\(code.searchable.formatted()) 个代码文件已可搜索" + waiting
    }

    /// A few words for the search bar while results may be incomplete: "Indexing 42%", "Downloading model · 42%".
    var activityBadge: String? {
        if download.isActive { return "正在下载模型 · \(Int(download.fraction * 100))%" }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return "正在建立索引 \(Int(Double(done) / Double(total) * 100))%"
        }
        if status.paused, status.pending > 0 { return "已暂停建立索引" }
        return nil
    }

    /// Why meaning search can't run yet (words still match), or nil.
    var meaningUnavailable: String? {
        guard !download.isReady else { return nil }
        if download.isActive {
            return "模型下载中（\(Int(download.fraction * 100))%），目前仅匹配文字"
        }
        return "模型尚未下载，目前仅匹配文字"
    }

    /// Why results may be incomplete right now, or nil.
    var resultsCaveat: String? {
        if let meaningUnavailable { return meaningUnavailable }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return "正在建立索引（\(Int(Double(done) / Double(total) * 100))%），部分文件尚不可搜索"
        }
        if status.pending > 0 {
            return "还有 \(status.pending.formatted()) 个文件尚未处理"
        }
        return nil
    }
}
