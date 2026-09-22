import SwiftUI

@MainActor
struct LibraryView: View {
    @Bindable var store: LibraryStore
    let downloads: DownloadStore
    let onImport: () -> Void
    let onDownload: (ModelRecord) -> Void
    let onEditLocal: (ModelRecord) -> Void
    let onShowDownloads: () -> Void
    @State private var selectionID: String?
    @State private var inspectorVisible = true
    @State private var compactInspectorPresented = false
    @State private var pendingInspectorAction: (() -> Void)?
    @State private var filtersPresented = false
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)]
    private var selectedModel: ModelRecord? { store.records.first { $0.id == selectionID } }
    private var hasAdvancedFilters: Bool { store.query.author != "全部作者" || store.query.category != "全部" }
    private var hasFilters: Bool {
        !store.query.text.isEmpty || store.query.source != nil || store.query.status != .all || hasAdvancedFilters
    }

    var body: some View {
        GeometryReader { geometry in
            // 窄窗口优先保证卡片和工具栏宽度，详情改用原生 Sheet；不会创建两份模型网格。
            let wide = geometry.size.width >= 1_060
            HStack(alignment: .top, spacing: 18) {
                libraryPane(wide: wide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if wide && inspectorVisible && !store.isLibraryEmpty {
                    inspector(close: { inspectorVisible = false })
                        .frame(width: 320)
                        .shelfSurface()
                }
            }
            .padding(20)
            .sheet(isPresented: $compactInspectorPresented, onDismiss: {
                if let action = pendingInspectorAction {
                    pendingInspectorAction = nil
                    action()
                }
            }) {
                inspector(close: { compactInspectorPresented = false })
                    .frame(width: 390, height: 650)
                    .background(ShelfTheme.card)
                    .onExitCommand { compactInspectorPresented = false }
            }
            .onChange(of: wide) { _, isWide in
                if isWide { compactInspectorPresented = false }
            }
        }
        .task(id: store.query) { await store.refresh(debounce: store.hasLoaded) }
        .onChange(of: store.records.map(\.id), initial: true) { _, ids in
            if selectionID == nil || !ids.contains(selectionID ?? "") {
                selectionID = ids.first
            }
        }
        .onChange(of: store.searchFocusRequest, initial: true) { _, request in
            if request > 0 { searchFocused = true }
        }
    }

    private func libraryPane(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !store.isLibraryEmpty { filters(wide: wide) }

            if let message = store.errorMessage {
                HStack {
                    NoticeBanner(text: message, symbol: "exclamationmark.triangle")
                    Button("重试") { Task { await store.refresh(debounce: false) } }
                        .buttonStyle(QuietButtonStyle())
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.isLibraryEmpty {
                        EmptyShelf(title: "模型库还是空的",
                                   description: "从模型链接、当前账号或作者导入模型，也可以添加自己的本地创作。",
                                   symbol: "cube.transparent", actionTitle: "添加模型", action: onImport)
                    } else if store.records.isEmpty && !store.isLoading {
                        EmptyShelf(title: "没有符合条件的模型",
                                   description: "试试其他来源、作者或下载状态。",
                                   symbol: "line.3.horizontal.decrease.circle",
                                   actionTitle: "清除筛选", action: clearFilters)
                    } else if store.layout == .grid {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(store.records) { model in
                                ModelCard(model: model, isSelected: selectionID == model.id,
                                          job: downloads.latestJobsByModel[model.id],
                                          onEdit: editAction(for: model)) {
                                    select(model, wide: wide)
                                }
                            }
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(store.records) { model in
                                ModelListRow(model: model, isSelected: selectionID == model.id,
                                             job: downloads.latestJobsByModel[model.id],
                                             onEdit: editAction(for: model)) {
                                    select(model, wide: wide)
                                }
                            }
                        }
                    }

                    if store.hasMore {
                        Button(store.isLoadingMore ? "正在加载…" : "加载更多（\(store.records.count) / \(store.total)）") {
                            Task { await store.loadMore() }
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(store.isLoadingMore || store.isLoading)
                    }
                    if !store.records.isEmpty {
                        Text("已显示 \(store.records.count) / \(store.total) 个模型")
                            .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                    }
                }
                .padding(2) // 为选中描边和卡片阴影留出空间。
                .padding(.bottom, 8)
            }
            .overlay {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                        .padding(14)
                        .background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                title
                Spacer(minLength: 8)
                search
                addButton
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack { title; Spacer(); addButton }
                search.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("模型库").font(.system(size: 27, weight: .semibold)).tracking(-0.6)
            Text("\(store.statistics.total) 个模型")
                .font(.system(size: 12)).foregroundStyle(ShelfTheme.muted).monospacedDigit()
        }
        .fixedSize()
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ShelfTheme.muted)
            TextField("搜索模型、作者…", text: $store.query.text)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("搜索模型名称、作者或副标题")
            if !store.query.text.isEmpty {
                Button { store.query.text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ShelfTheme.muted)
                }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            } else {
                Text("⌘K").font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 11)
        .frame(width: 220, height: 38)
        .background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShelfTheme.line))
    }

    private var addButton: some View {
        Button(action: onImport) {
            Label("添加模型", systemImage: "plus")
        }
        .buttonStyle(PrimaryButtonStyle())
        .fixedSize()
        .help("从账号、作者、模型链接导入，或新建本地模型（⌘N）")
    }

    private func filters(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sourceFilter
                    Spacer(minLength: 0)
                    filterControls(wide: wide)
                }
                VStack(alignment: .leading, spacing: 10) {
                    sourceFilter
                    HStack { filterControls(wide: wide); Spacer(minLength: 0) }
                }
            }
            if hasAdvancedFilters {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text([store.query.author == "全部作者" ? nil : store.query.author,
                          store.query.category == "全部" ? nil : store.query.category]
                        .compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    Button("清除") { clearAdvancedFilters() }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }
        }
    }

    /// 唯一的来源筛选入口；删除侧栏重复选项之后，筛选仍由原 LibraryQuery 驱动。
    private var sourceFilter: some View {
        Picker("模型来源", selection: $store.query.source) {
            Text("全部来源").tag(nil as LibrarySource?)
            ForEach(LibrarySource.allCases) { source in
                Text(source.rawValue).tag(Optional(source))
            }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(width: 310).controlSize(.large)
    }

    private func filterControls(wide: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                Picker("归档状态", selection: $store.query.status) {
                    Text("全部状态").tag(DownloadFilter.all)
                    Text("已归档").tag(DownloadFilter.downloaded)
                    Text("未下载").tag(DownloadFilter.pending)
                }
                Divider()
                Button("清除全部筛选", action: clearFilters).disabled(!hasFilters)
            } label: {
                menuLabel(store.query.status == .downloaded ? "已归档" : store.query.status.rawValue)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Menu {
                Picker("排序", selection: $store.query.sort) {
                    ForEach(ModelSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { menuLabel(store.query.sort.rawValue) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Button { filtersPresented.toggle() } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(hasAdvancedFilters ? ShelfTheme.ink : ShelfTheme.muted)
                    .frame(width: 32, height: 34)
                    .background(hasAdvancedFilters ? ShelfTheme.selection : ShelfTheme.card,
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).help("按作者、分类筛选").accessibilityLabel("更多筛选")
            .popover(isPresented: $filtersPresented) { advancedFilters }

            Picker("显示方式", selection: $store.layout) {
                Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid)
                Image(systemName: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 70)
            .help("切换网格或列表")

            if !wide || !inspectorVisible {
                Button {
                    if wide { inspectorVisible = true }
                    else { compactInspectorPresented = true }
                } label: {
                    Image(systemName: "sidebar.right").frame(width: 28, height: 34)
                }
                .buttonStyle(.plain).disabled(selectedModel == nil)
                .help("显示模型详情").accessibilityLabel("显示模型详情")
            }
        }
        .fixedSize()
    }

    private func menuLabel(_ value: String) -> some View {
        HStack(spacing: 8) {
            Text(value)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ShelfTheme.line))
    }

    private var advancedFilters: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更多筛选").font(.system(size: 15, weight: .semibold))
            Picker("作者", selection: $store.query.author) {
                Text("全部作者").tag("全部作者")
                ForEach(store.authors.filter { $0 != "全部作者" }, id: \.self) { Text($0).tag($0) }
            }
            Picker("分类", selection: $store.query.category) {
                Text("全部").tag("全部")
                ForEach(store.categories.filter { $0 != "全部" }, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button("重置", action: clearAdvancedFilters).buttonStyle(QuietButtonStyle())
                Spacer()
                Button("完成") { filtersPresented = false }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20).frame(width: 320)
        .background(ShelfTheme.card)
    }

    @ViewBuilder
    private func inspector(close: @escaping () -> Void) -> some View {
        if let selectedModel {
            LibraryInspectorView(model: selectedModel,
                                 job: downloads.latestJobsByModel[selectedModel.id],
                                 download: { onDownload(selectedModel) },
                                 showDownloads: { performAfterInspectorDismiss(onShowDownloads) },
                                 edit: editAction(for: selectedModel),
                                 close: close)
                .id("\(selectedModel.id):\(selectedModel.archivedAt?.timeIntervalSince1970 ?? 0)")
        } else {
            VStack(spacing: 16) {
                HStack {
                    Text("模型详情").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭模型详情")
                }
                Spacer()
                Image(systemName: "cube.transparent").font(.system(size: 32, weight: .light))
                Text("选择一个模型查看详情").font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(ShelfTheme.muted).padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ model: ModelRecord, wide: Bool) {
        selectionID = model.id
        if wide { inspectorVisible = true }
        else { compactInspectorPresented = true }
    }

    private func editAction(for model: ModelRecord) -> (() -> Void)? {
        guard model.canEditLocally else { return nil }
        return {
            performAfterInspectorDismiss { onEditLocal(model) }
        }
    }

    /// 窄窗口先完成详情弹窗的关闭，再编辑或切换页面，避免模态窗口争用和回调丢失。
    private func performAfterInspectorDismiss(_ action: @escaping () -> Void) {
        if compactInspectorPresented {
            pendingInspectorAction = action
            compactInspectorPresented = false
        } else {
            action()
        }
    }

    private func clearAdvancedFilters() {
        store.query.author = "全部作者"
        store.query.category = "全部"
    }

    private func clearFilters() {
        let sort = store.query.sort
        store.query = LibraryQuery()
        store.query.sort = sort
    }
}

@MainActor
private struct ModelListRow: View {
    let model: ModelRecord
    let isSelected: Bool
    let job: DownloadJob?
    var onEdit: (() -> Void)?
    let open: () -> Void
    @Environment(\.archiveRoot) private var archiveRoot

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                ModelArtwork(model: model, pixels: 160, archiveRoot: archiveRoot)
                    .frame(width: 76, height: 57)
                    .background(Color(hex: model.backgroundHex))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(model.author) · \(model.sourceLabel) · \(model.fileFormatLabel)")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 7) {
                    ModelLibraryStatus(model: model, job: job)
                    Text(String(format: "%.1f MB", model.sizeMB))
                        .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted).monospacedDigit()
                }
            }
            .padding(12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shelfSurface(radius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isSelected ? ShelfTheme.accent : .clear, lineWidth: 1.5))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("查看详情", systemImage: "sidebar.right", action: open)
            if let onEdit { Button("编辑模型", systemImage: "pencil", action: onEdit) }
        }
    }
}
