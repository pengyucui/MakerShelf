import SwiftUI

@main @MainActor
struct MakerShelfApp: App {
    @State private var app = AppState()

    var body: some Scene {
        Window("MakerShelf", id: "main") {
            ContentView(app: app)
        }
        .defaultSize(width: 1_560, height: 980)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加模型…") { app.sheet = .importModels }.keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { app.section = .settings }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索模型") {
                    NotificationCenter.default.post(name: .shelfFocusSearch, object: nil)
                }.keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
