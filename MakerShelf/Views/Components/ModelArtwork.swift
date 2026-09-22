import SwiftUI

private struct ArchiveRootKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var archiveRoot: URL? {
        get { self[ArchiveRootKey.self] }
        set { self[ArchiveRootKey.self] = newValue }
    }
}

@MainActor
struct ModelArtwork: View {
    let source: ArtworkSource
    let pixels: Int
    private let revision: String
    @State private var thumbnail: Thumbnail?
    @State private var failed = false
    @State private var visible = false

    init(name: String, pixels: Int) {
        self.source = .bundled(name)
        self.pixels = pixels
        self.revision = ""
    }

    init(source: ArtworkSource, pixels: Int, revision: String = "") {
        self.source = source
        self.pixels = pixels
        self.revision = revision
    }

    init(model: ModelRecord, pixels: Int, archiveRoot: URL? = nil) {
        self.source = model.artwork(archiveRoot: archiveRoot)
        self.pixels = pixels
        self.revision = model.archivedAt.map { String($0.timeIntervalSince1970) } ?? ""
    }

    var body: some View {
        // 图片只在父容器提供的区域内绘制，不把原图固有尺寸传回网格布局。
        GeometryReader { geometry in
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable().interpolation(.medium).scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "cube.transparent")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(ShelfTheme.muted.opacity(0.45))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false; thumbnail = nil }
        .task(id: "\(source):\(pixels):\(revision):\(visible)") {
            guard visible else { return }
            failed = false
            thumbnail = nil
            do {
                let result = try await ImagePipeline.shared.thumbnail(source, pixels: pixels, revision: revision)
                try Task.checkCancellation()
                guard visible else { return }
                thumbnail = result
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
        // 离屏时释放视图持有的缩略图；重新出现会因 visible 变化重启加载，优先命中共享缓存。
    }
}

/// 固定比例封面与固定信息区独立排版，标题长短和异步图片加载不会改变卡片高度。
@MainActor
struct ModelCard: View {
    let model: ModelRecord
    let isSelected: Bool
    let job: DownloadJob?
    let onEdit: (() -> Void)?
    let open: () -> Void
    @Environment(\.archiveRoot) private var archiveRoot
    @State private var hovered = false

    init(model: ModelRecord, isSelected: Bool = false, job: DownloadJob? = nil, onEdit: (() -> Void)? = nil, open: @escaping () -> Void) {
        self.model = model
        self.isSelected = isSelected
        self.job = job
        self.onEdit = onEdit
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    // 用底板确定 4:3 几何尺寸，再覆盖图片，禁止原图挤占文字区域。
                    Color(hex: model.backgroundHex)
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay {
                            ModelArtwork(model: model, pixels: 640, archiveRoot: archiveRoot)
                                .padding(5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.title).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ShelfTheme.ink)
                        Text(model.author).font(.system(size: 12))
                        Text("\(model.sourceLabel) · \(model.fileFormatLabel)")
                            .font(.system(size: 11))
                            .foregroundStyle(ShelfTheme.muted)
                    }
                    .foregroundStyle(ShelfTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 78, alignment: .center)
                    .padding(.horizontal, 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.title)，\(model.author)，\(model.sourceLabel)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            HStack {
                ModelLibraryStatus(model: model, job: job)
                Spacer(minLength: 0)
                Menu {
                    Button("查看详情", systemImage: "sidebar.right", action: open)
                    if let onEdit {
                        Button("编辑模型", systemImage: "pencil", action: onEdit)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(model.title)的更多操作")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .padding(6)
        .shelfSurface()
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? ShelfTheme.accent : (hovered ? ShelfTheme.muted.opacity(0.45) : .clear),
                              lineWidth: isSelected ? 1.5 : 1)
        }
        .contextMenu {
            Button("查看详情", systemImage: "sidebar.right", action: open)
            if let onEdit {
                Button("编辑模型", systemImage: "pencil", action: onEdit)
            }
        }
        .onHover { hovered = $0 }
    }
}

/// 卡片只观察任务阶段，百分比更新不会导致封面与文字重新布局。
@MainActor
struct ModelLibraryStatus: View {
    let model: ModelRecord
    let job: DownloadJob?

    var body: some View {
        if let job, job.phase != .completed && job.phase != .cancelled {
            HStack(spacing: 7) {
                Circle().fill(job.phase.statusColor).frame(width: 7, height: 7)
                Text(job.phase.rawValue)
            }
            .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        } else {
            StatusLabel(downloaded: model.isDownloaded, demo: model.isDemo)
        }
    }
}
