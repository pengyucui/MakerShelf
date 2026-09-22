import SwiftUI

@MainActor
struct DownloadsView: View {
    let store: DownloadStore
    let archivePath: String
    let onImport: () -> Void
    let onSettings: () -> Void
    @Environment(\.archiveRoot) private var archiveRoot

    private let metricColumns = [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    PageHeading(title: "下载任务", subtitle: "模型、介绍和展示图片一起归档。")
                    Spacer()
                    Button(action: onImport) { Label("添加模型", systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle())
                }

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    metric("square.stack.3d.up", label: "全部任务", value: "\(store.jobs.count)")
                    metric("clock", label: "等待完成", value: "\(store.pendingCount)")
                    metric("checkmark.circle", label: "已完成", value: "\(store.completedCount)")
                    metric("externaldrive", label: "模型总大小", value: String(format: "%.1f MB", store.totalMB))
                }

                GlassPanel {
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(ShelfTheme.ink)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("归档位置").font(.system(size: 11, weight: .semibold))
                            Text(archivePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ShelfTheme.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("修改", action: onSettings).buttonStyle(QuietButtonStyle())
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("下载队列").font(.system(size: 15, weight: .semibold))
                        Text(store.pendingCount == 0 ? "当前没有待处理任务" : "\(store.pendingCount) 个任务待处理")
                            .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    Button { store.pauseAll() } label: { Label("暂停全部", systemImage: "pause") }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!store.jobs.contains { $0.phase == .running || $0.phase == .queued })
                }

                if store.jobs.isEmpty {
                    EmptyShelf(title: "还没有下载任务",
                               description: "从模型链接或用户主页导入模型，确认后会显示在这里。",
                               symbol: "arrow.down.to.line", actionTitle: "添加模型", action: onImport)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.jobs) { job in
                            DownloadRow(job: job, archiveRoot: archiveRoot,
                                        pause: { store.pause(job) }, resume: { store.resume(job) },
                                        cancel: { store.cancel(job) })
                        }
                    }
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 24)
            .frame(maxWidth: 1_050, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func metric(_ symbol: String, label: String, value: String) -> some View {
        GlassPanel(padding: 14) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(ShelfTheme.ink)
                    .frame(width: 32, height: 32).background(ShelfTheme.selection, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    Text(label).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

@MainActor
private struct DownloadRow: View {
    let job: DownloadJob
    let archiveRoot: URL?
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ModelArtwork(model: job.model, pixels: 160, archiveRoot: archiveRoot)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(5)
                .frame(width: 72, height: 64).background(Color(hex: job.model.backgroundHex))
                .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(job.model.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    phaseBadge
                    Spacer()
                    Text(job.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                }
                Text("\(job.model.sourceLabel) · \(job.model.author)")
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
                ProgressView(value: job.progress).tint(ShelfTheme.accent)
                    .accessibilityLabel("\(job.model.title)下载进度")
                Text(job.errorMessage ?? job.statusText)
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
            }

            HStack(spacing: 6) {
                if job.phase == .queued || job.phase == .running {
                    actionButton("pause", help: "暂停", action: pause)
                } else if [.paused, .failed, .cancelled, .partial].contains(job.phase) {
                    actionButton(job.phase == .failed || job.phase == .partial ? "arrow.clockwise" : "play",
                                 help: job.phase == .failed || job.phase == .partial ? "重试" : "继续", action: resume)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ShelfTheme.green)
                }
                if job.phase != .completed && job.phase != .cancelled {
                    actionButton("xmark", help: "取消", action: cancel)
                }
            }
        }
        .padding(14)
        .shelfSurface(radius: 14)
    }

    private var phaseBadge: some View {
        Text(job.phase.rawValue).font(.system(size: 10, weight: .medium))
            .foregroundStyle(job.phase.statusColor)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(job.phase.statusColor.opacity(0.1), in: Capsule())
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26) }
            .buttonStyle(.borderless)
            .background(ShelfTheme.recessed, in: RoundedRectangle(cornerRadius: 8))
            .help(help)
            .accessibilityLabel(help)
    }
}


/// 下载状态颜色只表达任务语义，与深墨色的主要操作按钮分开。
extension DownloadPhase {
    var statusColor: Color {
        switch self {
        case .completed: return ShelfTheme.green
        case .running: return .blue
        case .failed: return .red
        case .partial: return .orange
        case .queued, .paused, .cancelled: return ShelfTheme.muted
        }
    }
}

/// 此层只寻找当前任务并观察阶段变化；高频 progress 由下一级独立视图读取。
@MainActor
struct DownloadActivityBar: View {
    let store: DownloadStore
    let showDownloads: () -> Void

    private var currentJob: DownloadJob? {
        for phase in [DownloadPhase.running, .queued, .paused, .failed, .partial] {
            // 同模型重新入队后只展示最新任务，避免下载成功后仍被旧失败记录占据摘要。
            if let job = store.jobs.first(where: {
                $0.phase == phase && store.latestJobsByModel[$0.model.id]?.id == $0.id
            }) { return job }
        }
        return nil
    }

    var body: some View {
        if let job = currentJob {
            DownloadActivityContent(job: job, pendingCount: store.pendingCount,
                                    showDownloads: showDownloads,
                                    pause: { store.pause(job) },
                                    resume: { store.resume(job) })
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .padding(.top, 2)
        }
    }
}

@MainActor
private struct DownloadActivityContent: View {
    let job: DownloadJob
    let pendingCount: Int
    let showDownloads: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    @Environment(\.archiveRoot) private var archiveRoot

    private var canPause: Bool { job.phase == .running || job.phase == .queued }
    private var needsRetry: Bool { job.phase == .failed || job.phase == .partial }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: showDownloads) {
                HStack(spacing: 11) {
                    ModelArtwork(model: job.model, pixels: 100, archiveRoot: archiveRoot)
                        .frame(width: 42, height: 36)
                        .background(Color(hex: job.model.backgroundHex))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.model.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(job.phase.rawValue).font(.system(size: 10))
                            .foregroundStyle(job.phase.statusColor)
                    }
                }
                .frame(width: 215, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(job.errorMessage ?? job.statusText)

            ProgressView(value: min(1, max(0, job.progress)))
                .tint(needsRetry ? job.phase.statusColor : ShelfTheme.accent)
                .accessibilityLabel("\(job.model.title)下载进度")
            Text(job.progress, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(ShelfTheme.muted).frame(width: 44)

            Button(action: showDownloads) {
                HStack(spacing: 7) {
                    Text(pendingCount > 0 ? "\(pendingCount) 个任务" : "查看任务")
                    Image(systemName: "chevron.up").font(.system(size: 9))
                }
                .font(.system(size: 11))
                .foregroundStyle(ShelfTheme.muted)
                .fixedSize()
            }.buttonStyle(.plain).accessibilityLabel("查看下载任务")

            Button(action: canPause ? pause : resume) {
                Image(systemName: canPause ? "pause.fill" : (needsRetry ? "arrow.clockwise" : "play.fill"))
                    .font(.system(size: 12))
                    .frame(width: 32, height: 32)
                    .background(ShelfTheme.recessed, in: Circle())
            }
            .buttonStyle(.plain)
            .help(canPause ? "暂停当前任务" : (needsRetry ? "重试当前任务" : "继续当前任务"))
            .accessibilityLabel(canPause ? "暂停当前任务" : (needsRetry ? "重试当前任务" : "继续当前任务"))
        }
        .padding(12)
        .shelfSurface(radius: 14)
    }
}
