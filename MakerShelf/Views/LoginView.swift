import AppKit
import Foundation

/// WKWebView in the SwiftUI process crashes on macOS 27 (WebKit Swift isolation).
/// Login runs in a separate Objective-C helper with no SwiftUI.
@MainActor
enum LoginPresenter {
    static func open(site: MakerSite, sessions: SessionStore, onConnected: @escaping () -> Void) {
        LoginHelperSession.shared.start(site: site, sessions: sessions, onConnected: onConnected)
    }
}

@MainActor
final class LoginHelperSession {
    static let shared = LoginHelperSession()
    private var process: Process?

    func start(site: MakerSite, sessions: SessionStore, onConnected: @escaping () -> Void) {
        stop()
        sessions.beginConnecting(site)
        guard let exe = helperURL(), FileManager.default.isExecutableFile(atPath: exe.path) else {
            sessions.failConnecting(site, message: "找不到独立登录程序 MakerShelfLogin。请重新安装 0.3.8。")
            return
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("makershelf-login-\(UUID().uuidString).json")
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = [
            "--url", site.loginURL.absoluteString,
            "--out", out.path,
            "--title", "连接 MakerWorld \(site.title)  ·  MakerShelf \(AppVersion.label)"
        ]
        process = proc
        do {
            try proc.run()
        } catch {
            sessions.failConnecting(site, message: "无法打开登录窗口：\(error.localizedDescription)")
            process = nil
            return
        }
        Task { @MainActor in
            while proc.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if self.process === proc { self.process = nil }
            let data = try? Data(contentsOf: out)
            try? FileManager.default.removeItem(at: out)
            guard let data else {
                sessions.cancelConnecting(site)
                return
            }
            if await sessions.complete(captureData: data, site: site) {
                onConnected()
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func helperURL() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "MakerShelfLogin") { return url }
        let fallback = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MakerShelfLogin")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
