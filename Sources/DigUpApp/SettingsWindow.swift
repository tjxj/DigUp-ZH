import AppKit
import DigUpKit
import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, folders, code, storage

    var title: String {
        switch self {
        case .general: "通用"
        case .folders: "文件夹"
        case .code: "代码"
        case .storage: "存储与隐私"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .storage: "internaldrive"
        }
    }
}

/// Settings, the way Mac apps lay them out: a toolbar of tabs, and the window sized to each one. Folders is also where
/// the index shows how far along it is, folder by folder.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: SettingsState
    /// Folders → Add Folders…, a sheet on this window.
    let addSheet: AddFoldersController
    /// Code → Add Folders… (code search's folders), a sheet on this window.
    let codeSheet: AddFoldersController
    private unowned let app: AppController
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(app: AppController) {
        self.app = app
        state = SettingsState(app: app)
        addSheet = AddFoldersController(app: app)
        codeSheet = AddFoldersController(app: app, code: true)
        super.init()
        state.addFolders = { [weak self] in self?.addFolders() }
        state.addCodeFolders = { [weak self] in self?.addCodeFolders() }
        for sheet in [addSheet, codeSheet] {
            sheet.onAdded = { [weak self] in
                guard let self else { return }
                Task { await self.state.refresh() }
            }
        }
    }

    /// Opens Add Folders on the Folders tab.
    func addFolders() {
        addSheet.begin(on: window)
    }

    /// Opens the code folders' sheet on the Code tab.
    func addCodeFolders() {
        codeSheet.begin(on: window)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ tab: SettingsTab = .general) {
        let window = self.window ?? makeWindow()
        tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        state.tab = tab
        Task { await state.refresh() }
        app.present(window)
    }

    var selectedTab: SettingsTab { state.tab }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: SettingsPane(tab: tab, state: state))
            controller.sizingOptions = .preferredContentSize
            controller.title = tab.title   // the window takes the selected tab's title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.tabs = tabs
        self.window = window
        state.selectTab = { [weak self] tab in
            self?.tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        addSheet.end()
        codeSheet.end()
        window?.contentViewController = nil
        window = nil
        tabs = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }
}

@Observable
final class SettingsState {
    var tab = SettingsTab.general
    private(set) var summaries: [Engine.RootSummary]?
    private(set) var codeSummaries: [Engine.RootSummary] = []
    private(set) var indexSize: Int64 = 0
    private(set) var codeIndexSize: Int64 = 0
    var launchAtLogin = false
    var loginProblem: String?
    var checksForUpdates = false
    @ObservationIgnored let app: AppController
    @ObservationIgnored var selectTab: (SettingsTab) -> Void = { _ in }
    @ObservationIgnored var addFolders: () -> Void = {}
    @ObservationIgnored var addCodeFolders: () -> Void = {}

    init(app: AppController) {
        self.app = app
    }

    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshPending = false

    var model: AppModel { app.model }

    func refresh() async {
        lastRefresh = Date()
        launchAtLogin = app.launchesAtLogin
        checksForUpdates = app.updates.automaticallyChecks
        indexSize = app.engine.indexSize
        codeIndexSize = app.engine.codeIndexSize
        codeSummaries = await app.engine.rootSummaries(code: true)
        summaries = await app.engine.rootSummaries()
    }

    /// The index changed: refresh the folder counts, at most every 2 s while files are being indexed.
    func statusChanged() {
        guard !refreshPending else { return }
        refreshPending = true
        let wait = max(0, 2 - Date().timeIntervalSince(lastRefresh))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            refreshPending = false
            await refresh()
        }
    }

    /// Ready to be drawn (debug snapshots wait for this).
    var isLoaded: Bool { summaries != nil }
}

/// One tab's content, at the width every tab shares.
private struct SettingsPane: View {
    let tab: SettingsTab
    let state: SettingsState

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(state: state)
            case .folders: FolderSettings(state: state)
            case .code: CodeSettings(state: state)
            case .storage: StorageSettings(state: state)
            }
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Bindable var state: SettingsState

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(combo: state.model.hotkey, apply: { state.app.setHotkey($0) },
                                     listening: { state.app.hotkeyRecording($0) }, capSize: 13)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("搜索快捷键")
                        Text("在任何应用中打开搜索面板。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { on in
                    state.loginProblem = state.app.setLaunchAtLogin(on)
                    state.launchAtLogin = state.app.launchesAtLogin
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时打开 DigUp-ZH")
                        Text(state.loginProblem ?? "登录后随时使用搜索快捷键。")
                            .font(.system(size: 11))
                            .foregroundStyle(state.loginProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            }
            Section {
                Text("前往 DigUp-ZH 的 GitHub 发布页查看并下载新版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                LabeledContent {
                    Button("查看发布页") { state.app.updates.checkNow() }
                } label: {
                    Text(state.model.updateAvailable.map { "DigUp-ZH \($0) 已发布" }
                         ?? "DigUp-ZH \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct FolderSettings: View {
    @Bindable var state: SettingsState
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                IndexProgress(model: state.model) { state.app.engine.setPaused(!state.model.status.paused) }
            }
            Section {
                if let summaries = state.summaries {
                    if summaries.isEmpty {
                        Text("尚未选择文件夹。添加你希望 DigUp-ZH 搜索的位置。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(summaries) { summary in
                        FolderStatusRow(summary: summary) { removing = summary }
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } header: {
                Text("搜索这些文件夹")
            } footer: {
                HStack {
                    Button(action: state.addFolders) {
                        Label("添加文件夹…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                ForEach(state.model.settings.excludedFolders, id: \.path) { folder in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(tildePath(folder.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            state.app.setExcluded(state.model.settings.excludedFolders.filter { $0 != folder })
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("重新搜索此文件夹")
                    }
                }
                if state.model.settings.excludedFolders.isEmpty {
                    Text("暂无。代码项目、应用和缓存会自动跳过，代码请在“代码”页单独设置。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("跳过这些文件夹")
            } footer: {
                HStack {
                    Button {
                        state.app.pickFolders(for: NSApp.keyWindow, prompt: "跳过") { folders in
                            guard !folders.isEmpty else { return }
                            state.app.setExcluded(state.model.settings.excludedFolders
                                + folders.filter { !state.model.settings.excludedFolders.contains($0) })
                        }
                    } label: {
                        Label("跳过文件夹…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                TypeExclusions(types: state.model.settings.excludedTypes) { state.app.setExcludedTypes($0) }
            } header: {
                Text("跳过这些文件类型")
            } footer: {
                Text("这里读取图片、PDF、文档（txt、md、rtf、docx、odt、html）和视频画面，不理解音频或视频对白。"
                     + "代码仅从“代码”页选定的文件夹中读取。密钥、证书、密码文件"
                     + "及 ~/.ssh 等隐藏文件夹会跳过。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.indexOnBattery },
                                     set: { state.app.setIndexOnBattery($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppSettings.batteryTitle)
                        Text(AppSettings.batteryDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.model.status) { state.statusChanged() }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) {
                guard let removing else { return }
                state.app.removeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text("此文件夹的 \(removing?.files.formatted() ?? "") 个文件将从索引中移除，原文件不受影响。以后添加回来时会"
                 + "重新建立索引。")
        }
    }

    private var removalTitle: String {
        "停止搜索“\(removing.map { ($0.path as NSString).lastPathComponent } ?? "")”？"
    }
}

/// Extensions typed as "heic, txt": applied on Return or when the field loses focus.
private struct TypeExclusions: View {
    let types: [String]
    let apply: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("扩展名", text: $text, prompt: Text("例如 heic, txt"))
            .labelsHidden()
            .focused($focused)
            .onSubmit { apply(text) }
            .onChange(of: focused) { _, now in if !now { apply(text) } }
            .onAppear { text = types.joined(separator: ", ") }
            .onChange(of: types) { _, now in text = now.joined(separator: ", ") }
    }
}

/// What the index is doing, with Pause/Resume.
private struct IndexProgress: View {
    let model: AppModel
    let togglePause: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.statusLine).font(.system(size: 13, weight: .semibold))
                if let progress = model.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasFolders {
                Button(model.status.paused ? "继续" : "暂停", action: togglePause)
            }
        }
    }

    /// "357 of 365 files searchable · 8 waiting · 2 long files to finish"
    private var detail: String {
        let status = model.status
        var text = "\(status.files.formatted()) 个文件中已有 \(status.searchable.formatted()) 个可搜索"
        if status.pending > 0 { text += " · \(status.pending.formatted()) 个待处理" }
        if status.unfinished > 0 {
            text += " · \(status.unfinished.formatted()) 个长文档尚未读完"
        }
        if model.download.isActive { text += " · 模型 \(model.download.progressText)" }
        return text
    }
}

private struct FolderStatusRow: View {
    let summary: Engine.RootSummary
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: summary.missing ? "/Volumes" : summary.path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(summary.missing ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((summary.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    if summary.missing || summary.unreadable {
                        Text(summary.missing ? "未连接" : "无访问权限")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if summary.unreadable {
                        Button("前往系统设置授权…", action: openFolderPrivacySettings)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                Text(tildePath(summary.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !summary.kinds.isEmpty {
                    KindCounts(counts: summary.kinds).padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.missing || summary.unreadable ? "保留索引，等待恢复访问"
                     : "已处理 \(summary.indexed.formatted()) / \(summary.files.formatted()) 个")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                if !states.isEmpty {
                    Text(states).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("停止搜索此文件夹")
            .accessibilityLabel("移除 \((summary.path as NSString).lastPathComponent)")
        }
        .padding(.vertical, 2)
    }

    private var states: String {
        [summary.pending > 0 ? "\(summary.pending.formatted()) 个待处理" : nil,
         summary.unfinished > 0
            ? "\(summary.unfinished.formatted()) 个长文档尚未读完" : nil,
         summary.skipped > 0 ? "\(summary.skipped.formatted()) 个已跳过" : nil,
         summary.failed > 0 ? "\(summary.failed.formatted()) 个读取失败" : nil].compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct StorageSettings: View {
    let state: SettingsState

    var body: some View {
        Form {
            Section("模型") {
                LabeledContent("Qwen3-VL-Embedding-2B") {
                    Text("Qwen · Apache 2.0 · 约 1.93 GB")
                }
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        Text(state.model.download.isReady ? "已就绪" : state.model.download.progressText)
                        switch state.model.download.phase {
                        case .needed, .failed:
                            Button("下载") { state.model.download.start() }.controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
                LabeledContent("位置") {
                    PathButton(url: state.model.settings.modelsDirectory)
                }
            }
            Section("搜索索引") {
                LabeledContent("占用空间", value: bytes(state.indexSize))
                if state.model.hasCode {
                    LabeledContent("代码索引", value: bytes(state.codeIndexSize))
                }
                LabeledContent("位置") {
                    PathButton(url: state.model.settings.indexDirectory)
                }
            }
            Section("隐私") {
                Text("DigUp-ZH 读取你选择的文件夹，将搜索索引保存在本机。"
                     + "完整安装包已内置模型，搜索可离线使用；仅缺失模型时需要联网下载。"
                     + "文件内容和搜索内容均不会上传。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("DigUp-ZH \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · "
                     + "致谢 DigUp、Qwen（Apache 2.0）及 llama.cpp（MIT）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Code search: its folders and how far along their index is, the editor results open in, and turning it off.
private struct CodeSettings: View {
    @Bindable var state: SettingsState
    @State private var turningOff = false
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("搜索代码").font(.system(size: 13, weight: .semibold))
                    Text("描述代码的用途，或输入函数、变量等名称。在搜索框输入 code:，例如"
                         + "“code: 请求失败后逐步延时重试”。代码单独建立索引，"
                         + "仅在代码搜索中显示。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.model.hasCode {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.model.codeStatusLine).font(.system(size: 12, weight: .medium))
                            if let indexing = state.model.status.code.indexing, indexing.total > 0 {
                                ProgressView(value: Double(indexing.done) / Double(indexing.total)).controlSize(.small)
                            }
                        }
                        Spacer()
                        Text(bytes(state.codeIndexSize))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if state.codeSummaries.isEmpty {
                    Text("尚未选择代码文件夹。请添加存放项目的文件夹。")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.codeSummaries) { summary in
                    FolderStatusRow(summary: summary) { removing = summary }
                }
            } header: {
                Text("代码文件夹")
            } footer: {
                HStack {
                    Button(action: state.addCodeFolders) {
                        Label(state.model.hasCode ? "添加文件夹…" : "选择代码文件夹…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                Picker("代码打开方式", selection: Binding(get: { CodeEditor.current.id },
                                                          set: { state.app.setCodeEditor($0) })) {
                    ForEach(CodeEditor.installed) { editor in Text(editor.name).tag(editor.id) }
                    Text(CodeEditor.defaultApp.name).tag(CodeEditor.defaultApp.id)
                }
            } footer: {
                Text("打开结果时跳转到匹配行。选中结果后按空格可快速预览整个文件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("代码索引和文档索引一样，仅保存在本机。"
                     + "会跳过 Git 忽略的文件、第三方依赖、自动生成的代码、数据文件及疑似"
                     + "密钥或密码的内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.model.hasCode {
                    HStack {
                        Spacer()
                        Button("关闭代码搜索…", role: .destructive) { turningOff = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.model.status) { state.statusChanged() }
        .confirmationDialog("关闭代码搜索？", isPresented: $turningOff) {
            Button("关闭", role: .destructive) {
                state.app.applyCodeFolders([], excluded: [])
                Task { await state.refresh() }
            }
        } message: {
            Text("将删除代码索引（\(bytes(state.codeIndexSize))），原代码文件不受影响。重新开启时会再次读取代码。")
        }
        .confirmationDialog("停止搜索“\(removing.map { ($0.path as NSString).lastPathComponent } ?? "")”中的代码？",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) {
                guard let removing else { return }
                state.app.removeCodeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text("此文件夹的 \(removing?.files.formatted() ?? "") 个代码文件将从索引中移除，原文件不受影响。")
        }
    }
}

/// "~/Library/…/Models" that shows the folder in Finder.
private struct PathButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 4) {
                Text(tildePath(url.path)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("在访达中显示")
    }
}
