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

    init(name: String, pixels: Int) {
        self.source = .bundled(name)
        self.pixels = pixels
        self.revision = ""
    }

    init(source: ArtworkSource, pixels: Int) {
        self.source = source
        self.pixels = pixels
        self.revision = ""
    }

    init(model: ModelRecord, pixels: Int, archiveRoot: URL? = nil) {
        self.source = model.artwork(archiveRoot: archiveRoot)
        self.pixels = pixels
        self.revision = model.archivedAt.map { String($0.timeIntervalSince1970) } ?? ""
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable().interpolation(.medium).scaledToFit()
            } else {
                Image(systemName: failed ? "photo.badge.exclamationmark" : "cube.transparent")
                    .font(.system(size: 27, weight: .light)).foregroundStyle(ShelfTheme.muted.opacity(0.45))
            }
        }
        .accessibilityHidden(true)
        .task(id: "\(source):\(pixels):\(revision)") {
            failed = false
            thumbnail = nil
            do {
                let result = try await ImagePipeline.shared.thumbnail(source, pixels: pixels)
                try Task.checkCancellation()
                thumbnail = result
            } catch is CancellationError {
            } catch { failed = true }
        }
        .onDisappear { thumbnail = nil }
    }
}

@MainActor
struct ModelCard: View {
    let model: ModelRecord
    let isSelected: Bool
    let onEdit: (() -> Void)?
    let open: () -> Void
    @Environment(\.archiveRoot) private var archiveRoot
    @State private var hovered = false

    init(model: ModelRecord, isSelected: Bool = false, onEdit: (() -> Void)? = nil, open: @escaping () -> Void) {
        self.model = model
        self.isSelected = isSelected
        self.onEdit = onEdit
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ModelArtwork(model: model, pixels: 640, archiveRoot: archiveRoot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                    .frame(height: 132)
                    .background(Color(hex: model.backgroundHex))
                    .clipped()
                Text(model.isLocal ? "LOCAL" : "3MF")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(9)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(model.author).font(.system(size: 9)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle().fill(model.isLocal ? .orange.opacity(0.8) : (model.site == .china ? ShelfTheme.green : .blue.opacity(0.7)))
                            .frame(width: 5, height: 5)
                        Text(model.sourceLabel).font(.system(size: 8)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer(minLength: 3)
                    Text(model.isDownloaded ? "已归档" : "未下载")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(model.isDownloaded ? ShelfTheme.green : ShelfTheme.muted)
                    if onEdit != nil {
                        Text("编辑")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(ShelfTheme.green)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture().onEnded { onEdit?() })
                    }
                }
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(ShelfTheme.line).frame(height: 1) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 10)
        }
        .frame(height: 214, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? ShelfTheme.green.opacity(0.55) : (hovered ? ShelfTheme.green.opacity(0.24) : ShelfTheme.line),
                              lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: ShelfTheme.ink.opacity(hovered || isSelected ? 0.10 : 0.06), radius: hovered || isSelected ? 12 : 6, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: open)
        .contextMenu {
            if let onEdit {
                Button("编辑本地模型", systemImage: "pencil", action: onEdit)
            }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(model.title)，\(model.author)，\(model.sourceLabel)，\(model.isDownloaded ? "已归档" : "未下载")")
        .accessibilityAction(named: "查看") { open() }
        .accessibilityAction(named: "编辑本地模型") { onEdit?() }
    }
}
