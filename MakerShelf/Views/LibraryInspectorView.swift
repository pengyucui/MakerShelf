import AppKit
import SwiftUI

private enum LibraryInspectorTab: String, CaseIterable, Identifiable {
    case introduction = "介绍"
    case files = "文件"
    case archive = "归档"
    var id: String { rawValue }
}

/// 模型库右侧常驻检查器。切换卡片时只更新这一列，主网格不离开当前浏览位置。
@MainActor
struct LibraryInspectorView: View {
    let model: ModelRecord
    let download: () -> Void
    let edit: (() -> Void)?

    @Environment(\.archiveRoot) private var archiveRoot
    @State private var tab: LibraryInspectorTab = .introduction
    @State private var imageIndex = 0

    private var gallery: [ArtworkSource] { model.gallery(archiveRoot: archiveRoot) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    artwork
                    if gallery.count > 1 { galleryPicker }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.title)
                            .font(.system(size: 20, weight: .semibold))
                            .lineLimit(3)
                        if !model.subtitle.isEmpty {
                            Text(model.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(ShelfTheme.muted)
                                .lineLimit(2)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(String(model.author.prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 25, height: 25)
                            .foregroundStyle(ShelfTheme.green)
                            .background(ShelfTheme.selection, in: Circle())
                        Text(model.author)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(model.category)
                            .font(.system(size: 9))
                            .foregroundStyle(ShelfTheme.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(ShelfTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }

                    HStack(spacing: 0) {
                        metric("\(model.fileCount)", label: "模型文件")
                        metric(String(format: "%.1f MB", model.sizeMB), label: "文件大小")
                        metric(model.isDownloaded ? "已归档" : "未下载", label: "本地状态")
                    }
                    .padding(.vertical, 11)
                    .overlay(alignment: .top) { Divider() }
                    .overlay(alignment: .bottom) { Divider() }

                    Picker("模型信息", selection: $tab) {
                        ForEach(LibraryInspectorTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    inspectorContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }

            actionBar
        }
        .background(.thinMaterial)
        .id("\(model.id):\(model.archivedAt?.timeIntervalSince1970 ?? 0)")
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let edit {
                Button(action: edit) {
                    Label("编辑本地模型", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            if model.isDownloaded, !model.isDemo, let archiveFolder {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([archiveFolder])
                } label: {
                    Label("在访达中显示", systemImage: "folder").frame(maxWidth: .infinity)
                }.buttonStyle(QuietButtonStyle())
            } else if model.isDownloaded {
                Label(model.isDemo ? "示例条目没有真实归档文件" : "模型已经保存在本地", systemImage: "checkmark.circle")
                    .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
            } else if !model.isLocal {
                Button(action: download) {
                    Label("下载此模型", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(ShelfTheme.line).frame(height: 1) }
    }

    private var artwork: some View {
        ZStack(alignment: .topLeading) {
            ModelArtwork(source: currentArtwork, pixels: 640)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .frame(height: 224)
                .background(Color(hex: model.backgroundHex))
                .clipped()
            Label(model.sourceLabel, systemImage: model.isLocal ? "externaldrive" : "globe")
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.48)))
    }

    private var currentArtwork: ArtworkSource {
        gallery.indices.contains(imageIndex) ? gallery[imageIndex] : model.artwork(archiveRoot: archiveRoot)
    }

    private var galleryPicker: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 7) {
                ForEach(gallery.indices, id: \.self) { index in
                    Button { imageIndex = index } label: {
                        ModelArtwork(source: gallery[index], pixels: 160)
                            .frame(width: 46, height: 36)
                            .background(Color(hex: model.backgroundHex))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                                imageIndex == index ? ShelfTheme.green : ShelfTheme.line,
                                lineWidth: imageIndex == index ? 2 : 1))
                    }.buttonStyle(.plain)
                }
            }
        }.scrollIndicators(.hidden)
    }

    private var archiveFolder: URL? {
        guard let path = model.archiveFolder else { return nil }
        return PathSafety.resolve(path, archiveRoot: archiveRoot)
    }

    @ViewBuilder private var inspectorContent: some View {
        switch tab {
        case .introduction:
            VStack(alignment: .leading, spacing: 12) {
                Text("关于这个设计").font(.system(size: 12, weight: .semibold))
                Text(model.plainSummary.isEmpty ? "暂无介绍。" : model.plainSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(ShelfTheme.muted)
                    .lineSpacing(5)
                    .lineLimit(8)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    infoTile("材料", value: model.material)
                    infoTile("打印时间", value: model.printTime)
                }
                if let raw = model.sourceURL, let url = URL(string: raw) {
                    Link(destination: url) {
                        Label("打开来源页面", systemImage: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                }
            }
        case .files:
            VStack(alignment: .leading, spacing: 7) {
                if model.files.isEmpty {
                    Label("\(model.fileCount) 个模型文件", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(ShelfTheme.muted)
                } else {
                    ForEach(model.files.prefix(10)) { file in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(ShelfTheme.green)
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(file.kind.uppercased()).foregroundStyle(ShelfTheme.muted)
                        }
                        .font(.system(size: 9))
                        .padding(9)
                        .background(ShelfTheme.card.opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        case .archive:
            VStack(alignment: .leading, spacing: 10) {
                Label("模型文件与打印配置", systemImage: "cube.transparent")
                Label("介绍与作者信息", systemImage: "text.alignleft")
                Label("封面与展示图片", systemImage: "photo.on.rectangle")
                Text(model.archiveFolder ?? "下载完成后显示归档位置")
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.system(size: 10))
            .foregroundStyle(ShelfTheme.muted)
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ShelfTheme.green)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label).font(.system(size: 8)).foregroundStyle(ShelfTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoTile(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8)).foregroundStyle(ShelfTheme.muted)
            Text(value.isEmpty ? "未填写" : value)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShelfTheme.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
