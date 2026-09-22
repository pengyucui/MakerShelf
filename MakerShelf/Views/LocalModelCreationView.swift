import SwiftUI
import UniformTypeIdentifiers

/// 从模型 Inspector 打开的独立编辑 Sheet，负责建立一次性的表单状态。
@MainActor
struct LocalModelEditView: View {
    let model: ModelRecord
    @Bindable var preferences: PreferencesStore
    let onSave: @MainActor (ModelRecord, LocalModelDraft) async throws -> Void
    @State private var store: LocalModelStore
    @Environment(\.dismiss) private var dismiss

    init(model: ModelRecord, preferences: PreferencesStore,
         onSave: @escaping @MainActor (ModelRecord, LocalModelDraft) async throws -> Void) {
        self.model = model
        self.preferences = preferences
        self.onSave = onSave
        _store = State(initialValue: LocalModelStore(existing: model, archiveRoot: preferences.archiveURL))
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
                    Text("EDIT LOCAL MODEL")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.3)
                        .foregroundStyle(ShelfTheme.green)
                    Text("编辑本地模型")
                        .font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Button {
                    store.save(using: { draft in try await onSave(model, draft) })
                } label: {
                    HStack(spacing: 8) {
                        if store.isSaving { ProgressView().controlSize(.small) }
                        Text(store.isSaving ? "正在保存…" : "保存修改")
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!store.canSave || preferences.archiveURL == nil || store.isSaving)
            }

            LocalModelCreationView(store: store,
                                   preferences: preferences,
                                   existing: model,
                                   showsIntro: false,
                                   showsFooterActions: false,
                                   onSave: { draft in try await onSave(model, draft) })
        }
        .padding(24)
        .frame(width: 940)
        .background(.regularMaterial)
        .foregroundStyle(ShelfTheme.ink)
        .onDisappear { store.cancelSave() }
    }
}

/// Native Glass 版的本地模型编辑器。新建与编辑共用同一套表单，文件操作仍交给后台服务。
@MainActor
struct LocalModelCreationView: View {
    @Bindable var store: LocalModelStore
    @Bindable var preferences: PreferencesStore
    let existing: ModelRecord?
    var showsIntro: Bool = true
    var showsFooterActions: Bool = true
    let onSave: @MainActor (LocalModelDraft) async throws -> Void

    @State private var showsModelImporter = false
    @State private var showsImageImporter = false
    @State private var isDropTargeted = false

    private static let modelContentTypes: [UTType] = ["3mf", "stl", "obj", "step", "stp", "gcode", "amf"]
        .compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                formPanel
                    .frame(maxWidth: .infinity)
                previewPanel
                    .frame(width: 272)
            }

            footer
        }
        .fileImporter(isPresented: $showsModelImporter,
                      allowedContentTypes: Self.modelContentTypes,
                      allowsMultipleSelection: true) { result in
            receive(result, asImages: false)
        }
        .fileImporter(isPresented: $showsImageImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            receive(result, asImages: true)
        }
    }

    private var formPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsIntro {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(existing == nil ? "从你的 Mac 添加模型" : "编辑本地模型")
                            .font(.system(size: 17, weight: .semibold))
                        Text(existing == nil
                             ? "模型文件、介绍与展示图片会被复制到归档目录，来源文件保持不变。"
                             : "修改资料、展示图片与模型文件；保存成功后更新现有归档。")
                            .font(.system(size: 11))
                            .foregroundStyle(ShelfTheme.muted)
                            .lineSpacing(3)
                    }
                } else {
                    Text(existing == nil
                         ? "整理自己的模型文件、介绍与展示图片，创建一份完整的本地藏品。"
                         : "修改资料、展示图片与模型文件；保存成功后更新现有归档。")
                        .font(.system(size: 11))
                        .foregroundStyle(ShelfTheme.muted)
                        .lineSpacing(3)
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        field("模型名称 *") {
                            TextField("例如：桌面线材收纳盒", text: $store.title)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("作者") {
                            TextField("我", text: $store.author)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(width: 150)
                    }
                    GridRow {
                        field("副标题") {
                            TextField("一句话描述这个设计", text: $store.subtitle)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("分类") {
                            TextField("其他", text: $store.category)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(width: 150)
                    }
                }

                modelFileSection
                imageSection

                field("模型介绍") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $store.summary)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(7)
                        if store.summary.isEmpty {
                            Text("记录设计用途、打印建议或组装说明……")
                                .font(.system(size: 12))
                                .foregroundStyle(ShelfTheme.muted.opacity(0.72))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 15)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 94)
                    .background(ShelfTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ShelfTheme.line))
                }

                DisclosureGroup("更多打印资料") {
                    HStack(alignment: .top, spacing: 14) {
                        field("材料") {
                            TextField("例如：PLA", text: $store.material)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("预估打印时间") {
                            TextField("例如：2 小时 30 分", text: $store.printTime)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.top, 12)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .padding(18)
        }
        .scrollIndicators(.visible)
        .frame(height: 520)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.52)))
    }

    private var modelFileSection: some View {
        field("模型文件 *") {
            VStack(alignment: .leading, spacing: 10) {
                Button { showsModelImporter = true } label: {
                    VStack(spacing: 9) {
                        Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "cube.transparent")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(isDropTargeted ? .white : ShelfTheme.green)
                        Text(isDropTargeted ? "松开以添加模型" : "拖入 3MF、STL 或 STEP 文件")
                            .font(.system(size: 12, weight: .medium))
                        Text("也可点按这里使用系统文件选择器 · 支持多选")
                            .font(.system(size: 10))
                            .foregroundStyle(isDropTargeted ? .white.opacity(0.82) : ShelfTheme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(isDropTargeted ? ShelfTheme.green.opacity(0.9) : ShelfTheme.sidebar.opacity(0.72),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isDropTargeted ? Color.white.opacity(0.75) : ShelfTheme.green.opacity(0.35),
                                          style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    }
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    store.addModelFiles(urls)
                    return true
                } isTargeted: { isDropTargeted = $0 }

                if !store.modelFiles.isEmpty {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(store.modelFiles.prefix(12)), id: \.self) { url in
                            selectedFileRow(url)
                        }
                        if store.modelFiles.count > 12 {
                            Text("另有 \(store.modelFiles.count - 12) 个文件，保存时会全部归档。")
                                .font(.system(size: 10))
                                .foregroundStyle(ShelfTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var imageSection: some View {
        field("展示图片") {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    Button { showsImageImporter = true } label: {
                        VStack(spacing: 7) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 22, weight: .light))
                            Text("添加图片").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(ShelfTheme.green)
                        .frame(width: 104, height: 78)
                        .background(ShelfTheme.sidebar.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ShelfTheme.line))
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(store.imageFiles.enumerated()), id: \.element) { index, url in
                        imageTile(url, index: index)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("模型库预览", systemImage: "sparkles.rectangle.stack")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ShelfTheme.muted)

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let cover = store.imageFiles.first {
                            ModelArtwork(source: .file(cover), pixels: 480)
                        } else {
                            Image(systemName: "cube.transparent")
                                .font(.system(size: 44, weight: .ultraLight))
                                .foregroundStyle(ShelfTheme.muted.opacity(0.45))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176)
                    .background(ShelfTheme.sidebar.opacity(0.72))

                    Text("LOCAL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(.orange.opacity(0.82), in: Capsule())
                        .padding(10)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(previewTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Label(previewAuthor, systemImage: "person.crop.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(ShelfTheme.muted)
                        .lineLimit(1)
                    Divider()
                    HStack {
                        Label("本地模型", systemImage: "externaldrive")
                        Spacer()
                        Label("已归档", systemImage: "checkmark")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(ShelfTheme.green)
                }
                .padding(14)
            }
            .background(ShelfTheme.card.opacity(0.76), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.6)))
            .shadow(color: ShelfTheme.ink.opacity(0.08), radius: 18, y: 8)

            Label("完整本地归档", systemImage: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShelfTheme.green)

            VStack(alignment: .leading, spacing: 7) {
                Text("保存位置")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ShelfTheme.muted)
                Text(archivePreviewPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ShelfTheme.ink.opacity(0.82))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShelfTheme.sidebar.opacity(0.68), in: RoundedRectangle(cornerRadius: 9))

            Text("包含模型文件、展示图片、介绍页面与元数据。")
                .font(.system(size: 10))
                .foregroundStyle(ShelfTheme.muted)
                .lineSpacing(3)
        }
        .padding(16)
        .frame(height: 520, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.58)))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let error = store.errorMessage {
                NoticeBanner(text: error, symbol: "exclamationmark.triangle")
            }

            HStack(spacing: 12) {
                if preferences.archiveURL == nil {
                    Label("创建前请选择归档目录", systemImage: "folder.badge.questionmark")
                        .font(.system(size: 11))
                        .foregroundStyle(ShelfTheme.muted)
                    Button("选择目录") { preferences.selectArchiveFolder() }
                        .buttonStyle(QuietButtonStyle())
                } else {
                    Label(existing == nil
                          ? "原始文件只复制，不会被移动或修改"
                          : "保存成功后替换现有归档；模型 ID 与位置保持不变",
                          systemImage: existing == nil ? "doc.on.doc" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(ShelfTheme.muted)
                }

                Spacer()

                if showsFooterActions {
                    Button {
                        store.save(using: onSave)
                    } label: {
                        HStack(spacing: 8) {
                            if store.isSaving { ProgressView().controlSize(.small) }
                            Text(store.isSaving ? savingTitle : saveTitle)
                            Image(systemName: existing == nil ? "arrow.right" : "checkmark")
                        }
                        .frame(minWidth: 126)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canSave || preferences.archiveURL == nil)
                }
            }
        }
    }

    private func selectedFileRow(_ url: URL) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(ShelfTheme.green)
            Text(url.lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(url.pathExtension.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ShelfTheme.muted)
            Button { store.removeModelFile(url) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShelfTheme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ShelfTheme.card.opacity(0.64), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ShelfTheme.line.opacity(0.8)))
    }

    private func imageTile(_ url: URL, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            ModelArtwork(source: .file(url), pixels: 240)
                .frame(width: 104, height: 78)
                .background(ShelfTheme.sidebar, in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Button { store.removeImage(url) } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(5)

            if index == 0 {
                Text("封面")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ShelfTheme.green)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                Button("设为封面") { store.setCover(url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewTitle: String {
        let value = store.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名模型" : value
    }

    private var previewAuthor: String {
        let value = store.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = value.isEmpty ? "我" : value
        let category = store.category.trimmingCharacters(in: .whitespacesAndNewlines)
        return category.isEmpty ? author : "\(author) · \(category)"
    }

    private var archivePreviewPath: String {
        guard preferences.archiveURL != nil else { return "尚未选择归档目录" }
        if let path = existing?.archiveFolder { return "\(preferences.archivePath)/\(path)" }
        return "\(preferences.archivePath)/本地模型/\(PathSafety.component(previewTitle))"
    }

    private var saveTitle: String { existing == nil ? "添加到模型库" : "保存修改" }
    private var savingTitle: String { existing == nil ? "正在添加…" : "正在保存…" }

    private func receive(_ result: Result<[URL], any Error>, asImages: Bool) {
        switch result {
        case .success(let urls):
            if asImages { store.addImages(urls) } else { store.addModelFiles(urls) }
        case .failure(let error):
            store.reportSelectionError(error)
        }
    }
}
