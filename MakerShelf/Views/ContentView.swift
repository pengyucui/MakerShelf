import SwiftUI
import AppKit

@MainActor
struct ContentView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 204, ideal: 218, max: 260)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch app.section {
                    case .library:
                        LibraryView(store: app.library, downloads: app.downloads,
                                    recovery: app.archiveRecovery,
                                    onRecover: { app.settingsTab = .storage; app.section = .settings },
                                    onImport: { app.sheet = .importModels },
                                    onDownload: app.download,
                                    onEditLocal: { app.sheet = .editLocal($0) },
                                    onShowDownloads: { app.section = .downloads })
                    case .downloads:
                        DownloadsView(store: app.downloads, archivePath: app.preferences.archivePath,
                                      onImport: { app.sheet = .importModels },
                                      onSettings: { app.settingsTab = .storage; app.section = .settings })
                    case .settings:
                        SettingsView(preferences: app.preferences, sessions: app.sessions,
                                     recovery: app.archiveRecovery, tab: $app.settingsTab,
                                     onShowLibrary: { app.library.query = LibraryQuery(); app.section = .library })
                    case .logs:
                        LogsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 摘要自行观察队列与当前任务，根视图不读取任何 progress 属性。
                if app.section != .downloads && app.section != .logs {
                    DownloadActivityBar(store: app.downloads) { app.section = .downloads }
                }
            }
            .background(ShelfTheme.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .foregroundStyle(ShelfTheme.ink)
        .tint(ShelfTheme.accent)
        .frame(minWidth: 1_080, minHeight: 720)
        .environment(\.archiveRoot, app.preferences.archiveURL)
        .sheet(item: $app.sheet) { sheet in
            Group {
            switch sheet {
            case .importModels:
                ImportView(provider: app.provider, preferences: app.preferences, sessions: app.sessions,
                           categories: app.library.categories,
                           onEnqueue: app.enqueue, onCreateLocal: app.createLocalModel)
            case .editLocal(let model):
                LocalModelEditView(model: model, preferences: app.preferences,
                                   categories: app.library.categories, onSave: app.editLocalModel)
            }
            }
            .task {
                if !app.library.hasLoaded { await app.library.refresh(debounce: false) }
            }
        }
        .alert("MakerShelf", isPresented: Binding(get: { app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
            Button("知道了", role: .cancel) { app.notice = nil }
        } message: { Text(app.notice ?? "") }
        .onChange(of: app.preferences.maxConcurrentDownloads) { _, value in app.downloads.setConcurrency(value) }
        .onChange(of: app.preferences.archiveURL) { _, _ in app.archiveRecovery.directoryChanged() }
        .task { await app.archiveRecovery.restoreIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .shelfFocusSearch)) { _ in
            // 焦点请求保留到模型库重新挂载，避免从设置切回时丢失通知。
            app.section = .library
            app.library.searchFocusRequest += 1
        }
        .onDisappear { app.shutdown() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in app.shutdown() }
    }
}

extension Notification.Name {
    static let shelfFocusSearch = Notification.Name("MakerShelf.focusSearch")
}
