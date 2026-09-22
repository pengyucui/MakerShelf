import SwiftUI

/// 侧栏只表达页面导航；来源、状态、作者与分类统一在模型库筛选。
@MainActor
struct SidebarView: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(ShelfTheme.ink)
                VStack(alignment: .leading, spacing: 5) {
                    Text("MakerShelf").font(.system(size: 20, weight: .semibold)).tracking(-0.6)
                    Text("本地模型馆").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 24)
            .padding(.bottom, 28)

            VStack(spacing: 7) {
                ForEach(AppSection.allCases) { section in
                    Button { app.section = section } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 18, weight: .regular)).frame(width: 23)
                            Text(section.rawValue)
                                .font(.system(size: 13, weight: app.section == section ? .semibold : .regular))
                            Spacer(minLength: 0)
                            if section == .downloads {
                                SidebarDownloadBadge(store: app.downloads)
                            }
                        }
                        .foregroundStyle(app.section == section ? ShelfTheme.ink : ShelfTheme.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(app.section == section ? ShelfTheme.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(app.section == section ? .isSelected : [])
                }
            }

            Spacer(minLength: 24)
            SidebarArchiveSummary(library: app.library)
            Divider().overlay(ShelfTheme.line).padding(.vertical, 18)

            HStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ShelfTheme.muted)
                    .frame(width: 36, height: 36)
                    .background(ShelfTheme.selection, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的工作空间").font(.system(size: 12, weight: .medium))
                    Text("MakerShelf \(AppVersion.label)")
                        .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ShelfChrome().ignoresSafeArea() }
    }
}

/// 单独观察计数；每个任务的进度变化不触发导航栏重绘。
@MainActor
private struct SidebarDownloadBadge: View {
    let store: DownloadStore

    var body: some View {
        if store.pendingCount > 0 {
            Text(store.pendingCount, format: .number)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(ShelfTheme.selection, in: Capsule())
        }
    }
}

@MainActor
private struct SidebarArchiveSummary: View {
    let library: LibraryStore

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "folder").font(.system(size: 19)).foregroundStyle(ShelfTheme.muted)
            VStack(alignment: .leading, spacing: 6) {
                Text("本地归档").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                Text(storageLabel).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                Text("\(library.statistics.downloaded) 个已归档模型")
                    .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(ShelfTheme.line).frame(height: 1) }
        .help("按模型资料库索引统计，包含示例条目的标记容量；不是磁盘剩余空间。")
    }

    private var storageLabel: String {
        let mb = library.statistics.storedMB
        return mb >= 1_024 ? String(format: "%.1f GB", mb / 1_024) : String(format: "%.1f MB", mb)
    }
}
