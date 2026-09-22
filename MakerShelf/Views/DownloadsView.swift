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
                PageHeading(title: "下载任务", subtitle: "模型、介绍和展示图片会作为一个完整任务归档。")

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    metric("square.stack.3d.up", label: "全部任务", value: "\(store.jobs.count)")
                    metric("clock", label: "等待完成", value: "\(store.pendingCount)")
                    metric("checkmark.circle", label: "已完成", value: "\(store.completedCount)")
                    metric("externaldrive", label: "模型总大小", value: String(format: "%.1f MB", store.totalMB))
                }

                GlassPanel {
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(ShelfTheme.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("归档位置").font(.system(size: 11, weight: .semibold))
                            Text(archivePath)
                                .font(.system(size: 9, design: .monospaced))
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
                        Text(store.pendingCount == 0 ? "当前没有进行中的任务" : "正在处理 \(store.pendingCount) 个任务")
                            .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    Button { store.pauseAll() } label: { Label("暂停全部", systemImage: "pause") }
                        .buttonStyle(QuietButtonStyle()).disabled(store.pendingCount == 0)
                }

                if store.jobs.isEmpty {
                    EmptyShelf(title: "还没有下载任务",
                               description: "从模型链接或用户主页导入模型，确认后会显示在这里。",
                               symbol: "arrow.down.to.line", actionTitle: "导入模型", action: onImport)
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
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(ShelfTheme.green)
                    .frame(width: 32, height: 32).background(ShelfTheme.selection, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    Text(label).font(.system(size: 9)).foregroundStyle(ShelfTheme.muted)
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
                    .font(.system(size: 9)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
                ProgressView(value: job.progress).tint(ShelfTheme.green)
                    .accessibilityLabel("\(job.model.title)下载进度")
                Text(job.errorMessage ?? job.statusText)
                    .font(.system(size: 9)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
            }

            HStack(spacing: 6) {
                if job.phase == .queued || job.phase == .running {
                    actionButton("pause", help: "暂停", action: pause)
                } else if [.paused, .failed, .cancelled, .partial].contains(job.phase) {
                    actionButton(job.phase == .failed || job.phase == .partial ? "arrow.clockwise" : "play",
                                 help: "继续", action: resume)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ShelfTheme.green)
                }
                if job.phase != .completed && job.phase != .cancelled {
                    actionButton("xmark", help: "取消", action: cancel)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(ShelfTheme.line))
    }

    private var phaseBadge: some View {
        Text(job.phase.rawValue).font(.system(size: 8, weight: .medium))
            .foregroundStyle(job.phase == .failed ? Color.red : ShelfTheme.green)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background((job.phase == .failed ? Color.red : ShelfTheme.green).opacity(0.1), in: Capsule())
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26) }
            .buttonStyle(.borderless)
            .background(ShelfTheme.card.opacity(0.54), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(help)
    }
}
