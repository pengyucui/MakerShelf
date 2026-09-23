import SwiftUI

@MainActor
struct ImportView: View {
    @State private var store: ImportStore
    @State private var localStore = LocalModelStore()
    @Bindable var preferences: PreferencesStore
    let sessions: SessionStore
    let categories: [String]
    let onEnqueue: ([ModelRecord]) -> Void
    let onCreateLocal: @MainActor (LocalModelDraft) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.archiveRoot) private var archiveRoot
    init(provider: any ModelSourceProviding, preferences: PreferencesStore, sessions: SessionStore,
         categories: [String] = [],
         onEnqueue: @escaping ([ModelRecord]) -> Void,
         onCreateLocal: @escaping @MainActor (LocalModelDraft) async throws -> Void) {
        _store = State(initialValue: ImportStore(provider: provider))
        self.preferences = preferences
        self.sessions = sessions
        self.categories = categories
        self.onEnqueue = onEnqueue
        self.onCreateLocal = onCreateLocal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .background(ShelfTheme.ink.opacity(0.07), in: Circle())
                .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加到模型库").font(.system(size: 11, weight: .medium)).foregroundStyle(ShelfTheme.muted)
                    Text(headerTitle).font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                if store.source == .local {
                    Button("取消") { dismiss() }
                        .buttonStyle(QuietButtonStyle())
                    Button { localStore.save(using: onCreateLocal) } label: {
                        HStack(spacing: 8) {
                            if localStore.isSaving { ProgressView().controlSize(.small) }
                            Text(localStore.isSaving ? "正在添加…" : "添加到模型库")
                        }
                        .frame(minWidth: 88)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!localStore.canSave || preferences.archiveURL == nil || localStore.isSaving)
                }
            }
            Picker("导入来源", selection: $store.source) {
                ForEach(ImportSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 390)
            .frame(maxWidth: .infinity)
            if store.source == .local {
                LocalModelCreationView(store: localStore,
                                       preferences: preferences,
                                       existing: nil,
                                       categories: categories,
                                       showsIntro: false,
                                       showsFooterActions: false,
                                       onSave: onCreateLocal)
            } else if let preview = store.preview {
                previewList(preview)
            } else {
                form
            }
            if store.source != .local, let error = store.errorMessage {
                NoticeBanner(text: error, symbol: "exclamationmark.triangle")
                if let site = store.requiredSite {
                    Button("连接\(site.title)并继续") {
                        LoginPresenter.open(site: site, sessions: sessions) {
                            store.loadPreview(connectedSites: sessions.connectedSites())
                        }
                    }.buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(24)
        .frame(width: store.source == .local ? 940 : 760)
        .background(ShelfTheme.canvas)
        .foregroundStyle(ShelfTheme.ink)
        .onChange(of: store.source) { _, _ in
            store.input = ""
            store.edit()
        }
        .onDisappear {
            store.cancel()
            localStore.cancelSave()
        }
    }

    private var headerTitle: String {
        if store.source == .local { return "添加模型" }
        return store.preview == nil ? "添加模型" : "确认归档清单"
    }

    private var form: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 17) {
                    Text(store.source == .user ? "读取当前账号的收藏与作品，或读取指定作者的公开作品。" : "粘贴 MakerWorld 模型链接，先检查归档内容。")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                    if store.source == .user {
                        labeled("来源站点") {
                            Picker("来源站点", selection: $store.site) {
                                ForEach(MakerSite.allCases) { Text("MakerWorld \($0.title)").tag($0) }
                            }.labelsHidden()
                        }
                        labeled("目标用户") {
                            Picker("目标用户", selection: $store.target) {
                                ForEach(UserTarget.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                        }
                        if store.target == .specified {
                            labeled("用户名、用户 ID 或主页链接") {
                                TextField("输入账号、作者 ID 或主页链接", text: $store.input).textFieldStyle(.roundedBorder)
                            }
                        }
                        labeled("获取内容") {
                            Picker("获取内容", selection: $store.content) {
                                ForEach(availableUserContent) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                        }
                        Text(store.target == .current
                             ? "收藏与发布内容来自当前登录账号。"
                             : "指定作者支持用户名、@用户名、数字 ID 或主页链接；主页链接会自动识别站点。")
                            .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted).lineSpacing(4)
                    } else if store.source == .link {
                        labeled("模型链接") {
                            TextField("https://makerworld.com.cn/zh/models/…", text: $store.input).textFieldStyle(.roundedBorder)
                        }
                        Text("自动识别中文站或国际站。公开资料可以先预览，下载模型文件时再按需读取登录会话。")
                            .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted).lineSpacing(4)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                .shelfSurface()

                remoteArchivePanel.frame(width: 235)
            }
            Button {
                loadPreview()
            } label: {
                HStack {
                    if store.loading { ProgressView().controlSize(.small) }
                    Text(store.loading ? "正在获取清单…" : "预览导入清单")
                    Image(systemName: "arrow.right")
                }.frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryButtonStyle())
        }
        .disabled(store.loading)
        .onChange(of: store.site) { _, _ in store.edit() }
        .onChange(of: store.target) { _, target in
            // 指定作者只提供公开发布内容，切换目标时同步修正已选范围。
            if target == .specified { store.content = .published }
            store.edit()
        }
        .onChange(of: store.content) { _, _ in store.edit() }
        .onChange(of: store.input) { _, _ in
            store.errorMessage = nil
            // 粘贴作者主页后同步更新站点选择，让界面状态与实际请求保持一致。
            if store.target == .specified { store.site = store.effectiveSite }
        }
    }

    private var remoteArchivePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("完整归档", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(ShelfTheme.green)
            archiveItem("cube.transparent", "模型与打印配置")
            archiveItem("text.alignleft", "原始介绍与作者")
            archiveItem("photo.on.rectangle", "封面与展示图片")
            Divider()
            Text(store.canPreviewWithoutLogin ? "先预览公开资料，下载时按需连接账号。" : "使用当前所选站点的登录账号。")
                .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineSpacing(3)
            Spacer()
            Label("加入队列后写入归档目录", systemImage: "externaldrive")
                .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        }
        .padding(16)
        .frame(minHeight: 300, alignment: .topLeading)
        .shelfSurface()
    }

    private func archiveItem(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
    }

    private func loadPreview() {
        Task {
            // 当前账号内容需要登录；公开模型链接和指定作者作品无需提前读取钥匙串。
            if !store.canPreviewWithoutLogin {
                _ = await sessions.restoreIfNeeded(store.effectiveSite)
            }
            store.loadPreview(connectedSites: sessions.connectedSites())
        }
    }

    private var availableUserContent: [UserContent] {
        store.target == .current ? UserContent.allCases : [.published]
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func previewList(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            NoticeBanner(text: preview.notice)
            HStack {
                Text("已选 \(store.selectedIDs.count) / \(preview.records.count) 个模型").font(.system(size: 12))
                Spacer()
                Button("全选") { store.selectedIDs = Set(preview.records.map(\.id)) }.buttonStyle(.plain)
                Button("清空") { store.selectedIDs.removeAll() }.buttonStyle(.plain)
            }.foregroundStyle(ShelfTheme.ink)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(preview.records) { model in
                        HStack(spacing: 13) {
                            Toggle(model.title, isOn: Binding(get: { store.selectedIDs.contains(model.id) }, set: { selected in
                                if selected { store.selectedIDs.insert(model.id) } else { store.selectedIDs.remove(model.id) }
                            })).toggleStyle(.checkbox).labelsHidden()
                            ModelArtwork(model: model, pixels: 160, archiveRoot: archiveRoot).frame(width: 64, height: 58)
                                .background(Color(hex: model.backgroundHex), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.title).font(.system(size: 13, weight: .medium))
                                Text("\(model.author) · \(model.site.title)")
                                    .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                                if model.isDownloaded { Text("本地已有归档，再次加入将覆盖更新").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted) }
                            }
                            Spacer()
                        }.padding(10).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if preview.hasMore {
                        Button(store.loadingMore ? "正在加载…" : "加载更多（\(preview.records.count)/\(preview.total)）") {
                            store.loadMore()
                        }.buttonStyle(QuietButtonStyle()).disabled(store.loadingMore)
                    }
                }
            }.frame(maxHeight: 285)
            HStack {
                Button("返回修改") { store.edit() }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button { onEnqueue(store.selectedModels) } label: { Label("加入下载队列", systemImage: "arrow.down.to.line") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(store.selectedIDs.isEmpty)
            }
        }
    }
}
