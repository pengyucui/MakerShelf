import SwiftUI
import AppKit

@MainActor
struct ContentView: View {
    @Bindable var app: AppState
    @State private var searchRequested = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(app: app)
            VStack(spacing: 0) {
                topbar
                Group {
                    switch app.section {
                    case .library:
                        LibraryView(store: app.library,
                            onImport: { app.sheet = .importModels }, onDownload: app.download,
                            onEditLocal: { app.sheet = .editLocal($0) })
                    case .downloads:
                        DownloadsView(store: app.downloads, archivePath: app.preferences.archivePath,
                            onImport: { app.sheet = .importModels }, onSettings: { app.settingsTab = .storage; app.section = .settings })
                    case .settings:
                        SettingsView(preferences: app.preferences, sessions: app.sessions, tab: $app.settingsTab)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background {
                LinearGradient(colors: [ShelfTheme.canvas, ShelfTheme.sidebar.opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .foregroundStyle(ShelfTheme.ink).tint(ShelfTheme.green)
        .frame(minWidth: 1_080, minHeight: 720)
        .environment(\.archiveRoot, app.preferences.archiveURL)
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .importModels:
                ImportView(provider: app.provider, preferences: app.preferences, sessions: app.sessions,
                           onEnqueue: app.enqueue, onCreateLocal: app.createLocalModel)
            case .editLocal(let model):
                LocalModelEditView(model: model, preferences: app.preferences,
                                   onSave: app.editLocalModel)
            }
        }
        .alert("MakerShelf", isPresented: Binding(get: { app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
            Button("知道了", role: .cancel) { app.notice = nil }
        } message: { Text(app.notice ?? "") }
        .onChange(of: app.preferences.maxConcurrentDownloads) { _, value in app.downloads.setConcurrency(value) }
        .onReceive(NotificationCenter.default.publisher(for: .shelfFocusSearch)) { _ in
            app.section = .library
            searchRequested = true
        }
        .onDisappear { app.shutdown() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in app.shutdown() }
    }

    private var topbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.section.rawValue).font(.system(size: 13, weight: .semibold))
                Text(sectionSubtitle).font(.system(size: 9)).foregroundStyle(ShelfTheme.muted)
            }
            Spacer()
            if app.section == .library {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ShelfTheme.muted)
                    TextField("搜索名称、作者或材料", text: $app.library.query.text)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    Text("⌘K").font(.system(size: 9)).foregroundStyle(ShelfTheme.muted)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(width: 240, height: 30)
                .background(ShelfTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ShelfTheme.line))
            }
            if app.section != .settings {
                Button { app.sheet = .importModels } label: {
                    Label("导入模型", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            Menu {
                Button("设置") { app.section = .settings }
                Divider()
                Text("MakerShelf \(AppVersion.label)")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(ShelfTheme.line).frame(height: 1) }
        .onChange(of: searchRequested) { _, requested in
            if requested {
                app.section = .library
                searchFocused = true
                searchRequested = false
            }
        }
    }

    private var sectionSubtitle: String {
        switch app.section {
        case .library: return "\(app.library.statistics.total) 个模型"
        case .downloads: return "\(app.downloads.pendingCount) 个任务等待完成"
        case .settings: return "账号、存储与下载偏好"
        }
    }

}

extension Notification.Name {
    static let shelfFocusSearch = Notification.Name("MakerShelf.focusSearch")
}
