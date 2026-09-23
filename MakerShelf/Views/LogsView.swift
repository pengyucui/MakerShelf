import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 运行日志页面。只有页面可见时每秒取一次快照，不让日志通知驱动整个应用重绘。
@MainActor
struct LogsView: View {
    @State private var entries: [AppLogEntry] = []
    @State private var query = ""
    @State private var level: AppLogLevel?
    @State private var category: AppLogCategory?
    @State private var currentSessionOnly = false
    @State private var live = true
    @State private var selectedID: UUID?
    @State private var storageError: String?
    @State private var notice: String?
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var exporting = false

    private var filtered: [AppLogEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            (level == nil || $0.level == level) && (category == nil || $0.category == category)
                && (!currentSessionOnly || $0.session == AppLog.shared.session)
                && (term.isEmpty || "\($0.message) \($0.detail) \($0.category.rawValue) \($0.level.rawValue) \($0.session)"
                    .localizedStandardContains(term))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(minLength: 20); actions }
                VStack(alignment: .leading, spacing: 12) { heading; actions }
            }
            HStack(spacing: 12) {
                metric("最近记录", value: entries.count, color: ShelfTheme.ink)
                metric("警告", value: entries.filter { $0.level == .warning }.count, color: .orange)
                metric("错误", value: entries.filter { $0.level == .error }.count, color: .red)
            }
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { search; filters }
                    VStack(alignment: .leading, spacing: 12) { search; filters }
                }
                HStack {
                    Toggle("仅本次运行", isOn: $currentSessionOnly)
                    Spacer()
                    Toggle("实时更新", isOn: $live)
                    Text("匹配 \(filtered.count) 条").foregroundStyle(ShelfTheme.muted).monospacedDigit()
                }
                .font(.system(size: 11))
            }
            .zIndex(2)

            if let storageError {
                NoticeBanner(text: "日志暂时无法保存到磁盘，当前记录仍可查看与导出。\n\(storageError)", symbol: "exclamationmark.triangle")
            }
            if let notice { NoticeBanner(text: notice) }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        EmptyShelf(title: entries.isEmpty ? "暂无日志" : "没有匹配的日志",
                                   description: "执行一次导入、下载或文件预览后，可在这里查看记录；也可以调整搜索条件。",
                                   symbol: "text.magnifyingglass")
                    }
                    ForEach(filtered) { entry in
                        logRow(entry)
                    }
                }
                .padding(2)
            }
            Text("日志仅保存在本机 · 最近 2,000 条 · 文件轮转保留最多约 6 MiB · 导出范围为当前筛选结果")
                .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if live { await refresh() }
            }
        }
        .confirmationDialog("清空本机保存的全部日志？此操作不可撤销。", isPresented: $confirmingClear) {
            Button("清空日志", role: .destructive) {
                clearing = true
                Task {
                    notice = await AppLog.shared.clear()
                    selectedID = nil
                    await refresh()
                    clearing = false
                }
            }
        }
    }

    private var heading: some View {
        PageHeading(title: "运行日志", subtitle: "查看操作过程与失败原因，快速定位问题。")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(QuietButtonStyle()).help("刷新日志").accessibilityLabel("刷新日志")
            Button("清空") { confirmingClear = true }.buttonStyle(QuietButtonStyle()).disabled(clearing)
            Button(action: export) { Label(exporting ? "正在导出…" : "导出日志", systemImage: "square.and.arrow.up") }
                .buttonStyle(PrimaryButtonStyle()).disabled(filtered.isEmpty || exporting)
        }
    }

    private var search: some View {
        LogSearchField(text: $query, suggestions: ["STL", "OBJ", "3MF", "预览", "失败", "取消", "压缩"]
                       + AppLogCategory.allCases.map(\.rawValue))
            .frame(width: 290).zIndex(3)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("级别", selection: $level) {
                Text("全部级别").tag(nil as AppLogLevel?)
                ForEach(AppLogLevel.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.frame(width: 140)
            Picker("模块", selection: $category) {
                Text("全部模块").tag(nil as AppLogCategory?)
                ForEach(AppLogCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.frame(width: 160)
            Button("重置") { query = ""; level = nil; category = nil; currentSessionOnly = false }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        }
        .labelsHidden()
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
            Spacer()
            Text(value, format: .number).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
        .padding(16).shelfSurface()
    }

    private func logRow(_ entry: AppLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { selectedID = selectedID == entry.id ? nil : entry.id } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(entry.level.rawValue).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(entry.level)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(color(entry.level).opacity(0.09), in: Capsule())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.message).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(entry.category.rawValue) · \(entry.date.formatted(date: .abbreviated, time: .standard))")
                            .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: selectedID == entry.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if selectedID == entry.id {
                Divider()
                Text(entry.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    notice = "已复制这条日志。"
                } label: { Label("复制日志", systemImage: "doc.on.doc") }.buttonStyle(QuietButtonStyle())
            }
        }.padding(14).shelfSurface(radius: 12)
    }

    private func color(_ level: AppLogLevel) -> Color {
        switch level { case .debug: return ShelfTheme.muted; case .info: return .blue; case .warning: return .orange; case .error: return .red }
    }

    private func refresh() async {
        let snapshot = await AppLog.shared.snapshot()
        guard !Task.isCancelled else { return }
        entries = snapshot.entries
        storageError = snapshot.storageError
    }

    private func export() {
        let snapshot = filtered
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MakerShelf-日志.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        panel.canCreateDirectories = true
        exporting = true
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else { exporting = false; return }
                do {
                    try await AppLog.export(snapshot, to: url)
                    notice = "已导出 \(snapshot.count) 条日志。"
                } catch { notice = "导出失败：\(AppLog.errorDescription(error))" }
                exporting = false
            }
        }
    }
}

/// 日志搜索支持描边输入框、清除按钮、可滚动候选和选中勾选。
@MainActor
private struct LogSearchField: View {
    @Binding var text: String
    let suggestions: [String]
    @State private var expanded = false
    @FocusState private var focused: Bool
    private var matches: [String] { suggestions.filter { text.isEmpty || $0.localizedStandardContains(text) } }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ShelfTheme.muted)
            TextField("搜索日志、文件名或错误…", text: $text)
                .textFieldStyle(.plain).focused($focused).onSubmit { expanded = false }
                .accessibilityLabel("搜索日志")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
            Button { expanded.toggle(); focused = expanded } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).accessibilityLabel("搜索建议")
        }
        .font(.system(size: 12)).padding(.horizontal, 12).frame(height: 38)
        .background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? ShelfTheme.accent : ShelfTheme.line))
        // 候选列表使用系统浮层，避免被筛选栏、日志滚动区或窄窗口布局裁切。
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: 3) {
                    if matches.isEmpty {
                        Text("没有匹配建议，可直接输入关键词")
                            .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    ForEach(matches, id: \.self) { value in
                        Button {
                            text = value
                            expanded = false
                            focused = false
                        } label: {
                            HStack {
                                Text(value)
                                Spacer()
                                if text == value { Image(systemName: "checkmark") }
                            }
                            .font(.system(size: 12)).foregroundStyle(ShelfTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(text == value ? ShelfTheme.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(5)
            }
            .frame(width: 290, height: min(220, CGFloat(max(1, matches.count)) * 36 + 10))
            .background(ShelfTheme.card)
        }
        .onChange(of: focused) { _, value in if value { expanded = true } }
        .onExitCommand { expanded = false; focused = false }
    }
}
