import SwiftUI

@MainActor
struct LibraryView: View {
    @Bindable var store: LibraryStore
    let onImport: () -> Void
    let onDownload: (ModelRecord) -> Void
    let onEditLocal: (ModelRecord) -> Void
    @State private var selectionID: String?
    @Environment(\.archiveRoot) private var archiveRoot
    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 268), spacing: 14)]
    private var selectedModel: ModelRecord? { store.records.first { $0.id == selectionID } }

    var body: some View {
        HStack(spacing: 0) {
            libraryPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !store.isLibraryEmpty {
                Divider()
                inspectorColumn
                    .frame(width: 328)
            }
        }
        .task(id: store.query) { await store.refresh(debounce: store.hasLoaded) }
        .onChange(of: store.records.map(\.id), initial: true) { _, ids in
            if selectionID == nil || !ids.contains(selectionID ?? "") {
                selectionID = ids.first
            }
        }
    }

    @ViewBuilder
    private var inspectorColumn: some View {
        if let selectedModel {
            LibraryInspectorView(model: selectedModel,
                                 download: { onDownload(selectedModel) },
                                 edit: selectedModel.canEditLocally ? { onEditLocal(selectedModel) } : nil)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(ShelfTheme.muted)
                Text("选择一个模型查看详情")
                    .font(.system(size: 12, weight: .medium))
                Text("介绍、文件和本地归档都会显示在这里。")
                    .font(.system(size: 10))
                    .foregroundStyle(ShelfTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
        }
    }

    private var libraryPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                if !store.isLibraryEmpty {
                    filters
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 28)
            .padding(.bottom, 8)

            if let message = store.errorMessage {
                HStack {
                    NoticeBanner(text: message, symbol: "exclamationmark.triangle")
                    Button("重试") { Task { await store.refresh(debounce: false) } }
                }
                .padding(.horizontal, 26)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.isLibraryEmpty {
                        EmptyShelf(title: "模型库还是空的",
                                   description: "从模型链接、用户主页导入收藏与作品，或添加自己的本地模型。文件、介绍和展示图片会归档到你选择的目录。",
                                   symbol: "cube.transparent", actionTitle: "导入模型", action: onImport)
                    } else if store.records.isEmpty && !store.isLoading {
                        EmptyShelf(title: "没有符合条件的模型", description: "试试其他筛选条件，或者导入新的模型。", symbol: "cube.transparent")
                    } else {
                        HStack {
                            Text("最近添加").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("显示 \(store.records.count) / \(store.total)")
                                .font(.system(size: 9))
                                .foregroundStyle(ShelfTheme.muted)
                        }
                        .padding(.top, 8)

                        if store.layout == .grid {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(store.records) { model in
                                    ModelCard(model: model, isSelected: selectionID == model.id,
                                              onEdit: model.canEditLocally ? { onEditLocal(model) } : nil) {
                                        selectionID = model.id
                                    }
                                }
                            }
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(store.records) { model in
                                    ModelListRow(model: model,
                                                 onEdit: model.canEditLocally ? { onEditLocal(model) } : nil) {
                                        selectionID = model.id
                                    }
                                }
                            }
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    if store.hasMore {
                        Button(store.isLoadingMore ? "正在加载…" : "加载更多（已显示 \(store.records.count) / \(store.total)）") {
                            Task { await store.loadMore() }
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(store.isLoadingMore || store.isLoading)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
            }
            .overlay(alignment: .top) {
                if store.isLoading {
                    ProgressView().controlSize(.small).padding(8).background(.regularMaterial, in: Capsule())
                }
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .bottom) {
            PageHeading(title: "我的模型", subtitle: store.isLibraryEmpty
                ? "导入 MakerWorld 模型，或添加自己的本地模型。"
                : "收藏、下载与自己的创作，都在一个本地资料库里。")
            Spacer(minLength: 16)
            if !store.isLibraryEmpty {
                HStack(spacing: 24) {
                    summaryStat(store.statistics.total, label: "全部模型")
                    summaryStat(store.statistics.downloaded, label: "已归档")
                    summaryStat(store.statistics.authorCount, label: "位作者")
                }
            }
        }
    }

    private func summaryStat(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ShelfTheme.green)
                .monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(ShelfTheme.muted)
        }
        .frame(minWidth: 54, alignment: .leading)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("来源", selection: $store.query.source) {
                Text("全部").tag(nil as LibrarySource?)
                ForEach(LibrarySource.allCases) { source in Text(source.rawValue).tag(Optional(source)) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .labelsHidden()
            Spacer()
            Picker("排序", selection: $store.query.sort) {
                ForEach(ModelSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 108)
            Picker("显示方式", selection: $store.layout) {
                Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid)
                Image(systemName: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 72)
            .labelsHidden()
        }
        .padding(.top, 24)
    }
}

@MainActor
private struct ModelListRow: View {
    let model: ModelRecord
    var onEdit: (() -> Void)?
    let open: () -> Void
    @Environment(\.archiveRoot) private var archiveRoot
    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                ModelArtwork(model: model, pixels: 160, archiveRoot: archiveRoot).frame(width: 72, height: 58)
                    .background(Color(hex: model.backgroundHex), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.system(size: 13, weight: .medium))
                    Text(model.author).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                }
                Spacer()
                Text(model.sourceLabel).frame(width: 70)
                Text(String(format: "%.1f MB", model.sizeMB)).monospacedDigit().frame(width: 80)
                StatusLabel(downloaded: model.isDownloaded).frame(width: 115, alignment: .trailing)
                Image(systemName: "chevron.right").foregroundStyle(ShelfTheme.muted)
            }.font(.system(size: 11)).padding(13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onEdit {
                Button("编辑本地模型", systemImage: "pencil", action: onEdit)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(ShelfTheme.line).frame(height: 1) }
    }
}
