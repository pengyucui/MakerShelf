import AppKit
import SwiftUI

private enum LibraryInspectorTab: String, CaseIterable, Identifiable {
    case introduction = "介绍"
    case files = "文件"
    case archive = "归档"
    var id: String { rawValue }
}

/// 常驻详情与窄窗口 Sheet 共用同一内容；模型变化只重建详情，不影响主网格滚动。
@MainActor
struct LibraryInspectorView: View {
    let model: ModelRecord
    let job: DownloadJob?
    let download: () -> Void
    let showDownloads: () -> Void
    let edit: (() -> Void)?
    let close: () -> Void

    @Environment(\.archiveRoot) private var archiveRoot
    @State private var tab: LibraryInspectorTab = .introduction
    @State private var imageIndex = 0

    private var gallery: [ArtworkSource] { model.gallery(archiveRoot: archiveRoot) }
    private var revision: String { model.archivedAt.map { String($0.timeIntervalSince1970) } ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("模型详情").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12))
                        .foregroundStyle(ShelfTheme.muted).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).help("关闭模型详情").accessibilityLabel("关闭模型详情")
            }
            .padding(18)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    artwork
                    if gallery.count > 1 { galleryPicker }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.title).font(.system(size: 22, weight: .semibold))
                            .lineLimit(3).textSelection(.enabled)
                        Text(model.author).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ShelfTheme.muted).textSelection(.enabled)
                        if !model.subtitle.isEmpty {
                            Text(model.subtitle).font(.system(size: 11))
                                .foregroundStyle(ShelfTheme.muted).lineLimit(2)
                        }
                        HStack(spacing: 10) {
                            Text(model.sourceLabel).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(model.isLocal ? ShelfTheme.ink : Color.blue)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(model.isLocal ? ShelfTheme.recessed : Color.blue.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 7))
                            ModelLibraryStatus(model: model, job: job)
                        }
                        .padding(.top, 2)
                    }

                    Picker("模型信息", selection: $tab) {
                        ForEach(LibraryInspectorTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.large)

                    inspectorContent.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artwork: some View {
        Color(hex: model.backgroundHex)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                ModelArtwork(source: currentArtwork, pixels: 800, revision: revision)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var currentArtwork: ArtworkSource {
        gallery.indices.contains(imageIndex) ? gallery[imageIndex] : model.artwork(archiveRoot: archiveRoot)
    }

    private var galleryPicker: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(gallery.indices, id: \.self) { index in
                    Button { imageIndex = index } label: {
                        ModelArtwork(source: gallery[index], pixels: 200, revision: revision)
                            .frame(width: 82, height: 62)
                            .background(Color(hex: model.backgroundHex))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(imageIndex == index ? ShelfTheme.accent : ShelfTheme.line,
                                              lineWidth: imageIndex == index ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展示图片 \(index + 1)")
                    .accessibilityAddTraits(imageIndex == index ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var inspectorContent: some View {
        switch tab {
        case .introduction:
            VStack(alignment: .leading, spacing: 16) {
                introduction

                HStack(spacing: 0) {
                    metric("\(model.fileCount) 个文件")
                    Divider().frame(height: 16)
                    metric(String(format: "%.1f MB", model.sizeMB))
                    Divider().frame(height: 16)
                    metric(model.fileFormatLabel)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Divider().overlay(ShelfTheme.line) }
                .overlay(alignment: .bottom) { Divider().overlay(ShelfTheme.line) }

                HStack(spacing: 8) {
                    infoTile("材料", value: model.material)
                    infoTile("打印时间", value: model.printTime)
                }
                if !model.category.isEmpty {
                    Label(model.category, systemImage: "tag")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                }
                Label(archiveSummary, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineSpacing(4)

                if let raw = model.sourceURL, let url = URL(string: raw) {
                    Link(destination: url) {
                        Label("打开来源页面", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                }
            }
        case .files:
            LazyVStack(alignment: .leading, spacing: 8) {
                if model.files.isEmpty {
                    NoticeBanner(text: model.isDownloaded ? "暂无文件清单。" : "文件清单会在解析或下载后显示。", symbol: "doc")
                } else {
                    // 完整保留文件列表；惰性创建行，避免将十个以后的文件隐藏。
                    ForEach(model.files) { file in
                        HStack(spacing: 9) {
                            Image(systemName: "doc").foregroundStyle(ShelfTheme.muted)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(file.name).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
                                Text(file.kind.uppercased()).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(11)
                        .background(ShelfTheme.recessed, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        case .archive:
            VStack(alignment: .leading, spacing: 13) {
                Label("模型文件与打印配置", systemImage: "cube.transparent")
                Label("介绍与作者信息", systemImage: "text.alignleft")
                Label("封面与展示图片", systemImage: "photo.on.rectangle")
                Divider()
                Text(model.isDemo ? "示例条目没有真实归档文件。" : (model.archiveFolder ?? "下载完成后显示归档位置"))
                    .textSelection(.enabled)
                if let date = model.archivedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                }
                if let license = model.license, !license.isEmpty {
                    Text("模型许可：\(license)").textSelection(.enabled)
                }
                ForEach(model.warnings.indices, id: \.self) { index in
                    NoticeBanner(text: model.warnings[index], symbol: "exclamationmark.triangle")
                }
            }
            .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        }
    }

    /// 使用完整介绍按原顺序展示文字与插图；优先解析归档图片，避免只显示清单摘要。
    private var introduction: some View {
        let blocks = DescriptionBlocks.parse(model.introductionHTML, archiveRoot: archiveRoot,
                                             archiveFolder: model.archiveFolder, localImages: model.localImagePaths)
        return LazyVStack(alignment: .leading, spacing: 12) {
            if blocks.isEmpty {
                Text(model.plainSummary.isEmpty ? "暂无介绍。" : model.plainSummary)
                    .textSelection(.enabled)
            } else {
                ForEach(blocks.indices, id: \.self) { index in
                    switch blocks[index] {
                    case .text(let text):
                        Text(text).textSelection(.enabled)
                    case .image(let source):
                        ModelArtwork(source: source, pixels: 800, revision: revision)
                            .frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .background(ShelfTheme.recessed, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .font(.system(size: 12)).lineSpacing(5)
        .foregroundStyle(ShelfTheme.muted)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            // 已有未完成任务时直接进入队列处理，避免“下载此模型”重复入队或无法恢复暂停任务。
            if hasUnfinishedJob {
                Button(action: showDownloads) {
                    Label("查看下载任务", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle())
            }
            if model.isDownloaded, !model.isDemo, let archiveFolder {
                // 320 点详情栏纵向排列操作，给中文按钮文字留下完整宽度。
                Button { NSWorkspace.shared.activateFileViewerSelecting([archiveFolder]) } label: {
                    Label("在访达中显示", systemImage: "folder").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle())
            } else if model.isDownloaded {
                Label(model.isDemo ? "示例条目没有真实归档文件" : "请在设置中重新选择归档目录",
                      systemImage: model.isDemo ? "info.circle" : "folder.badge.questionmark")
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            } else if !model.isLocal && !hasUnfinishedJob {
                Button(action: download) {
                    Label("下载此模型", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle())
            }
            if let edit {
                Button(action: edit) {
                    Label("编辑模型", systemImage: "pencil").frame(maxWidth: .infinity)
                }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(ShelfTheme.line.opacity(0.7)).frame(height: 1) }
    }

    private var hasUnfinishedJob: Bool {
        guard let job else { return false }
        return job.phase != .completed && job.phase != .cancelled
    }

    private var archiveFolder: URL? {
        guard let path = model.archiveFolder else { return nil }
        return PathSafety.resolve(path, archiveRoot: archiveRoot)
    }

    private var archiveSummary: String {
        if model.isDemo { return "示例模型用于展示界面，不代表真实归档。" }
        if !model.warnings.isEmpty { return "归档部分完成，详情请查看“归档”页。" }
        return model.isDownloaded ? "模型文件、介绍和图片已保存在本地。" : "下载后将归档模型文件、介绍和图片。"
    }

    private func metric(_ value: String) -> some View {
        Text(value).font(.system(size: 11, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }

    private func infoTile(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
            Text(value.isEmpty ? "未填写" : value).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(ShelfTheme.recessed, in: RoundedRectangle(cornerRadius: 10))
    }
}
