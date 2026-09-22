import AppKit
import Foundation
import Observation

/// 偏好是真实本地设置。归档目录使用安全作用域书签，在读写期间保持访问。
@MainActor @Observable
final class PreferencesStore {
    var maxConcurrentDownloads: Int {
        didSet { defaults.set(maxConcurrentDownloads, forKey: "maxConcurrentDownloads") }
    }
    var preferredFormat: String {
        didSet { defaults.set(preferredFormat, forKey: "preferredFormat") }
    }
    private(set) var archiveURL: URL?
    var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessingArchive = false

    var archivePath: String { archiveURL?.path(percentEncoded: false) ?? "尚未选择归档目录" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedLimit = defaults.integer(forKey: "maxConcurrentDownloads")
        maxConcurrentDownloads = storedLimit == 0 ? 2 : min(3, max(1, storedLimit))
        preferredFormat = defaults.string(forKey: "preferredFormat") ?? "全部可用格式"
        if let bookmark = defaults.data(forKey: "archiveBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                archiveURL = url
                accessingArchive = url.startAccessingSecurityScopedResource()
                if stale {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    try saveBookmark(url)
                }
            } catch {
                archiveURL = nil
                errorMessage = "归档目录授权已失效，请重新选择目录。"
            }
        }
    }

    func selectArchiveFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择模型归档目录"
        panel.prompt = "选择目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = archiveURL
        // 异步原生选择器，不使用 runModal 阻塞主线程事件处理。
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    try self.saveBookmark(url)
                    if self.accessingArchive, let previous = self.archiveURL {
                        previous.stopAccessingSecurityScopedResource()
                    }
                    self.archiveURL = url
                    self.accessingArchive = url.startAccessingSecurityScopedResource()
                    self.errorMessage = nil
                } catch { self.errorMessage = "无法保存目录授权：\(error.localizedDescription)" }
            }
        }
    }

    private func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: "archiveBookmark")
    }

    func scopedArchiveURL() throws -> URL {
        guard let archiveURL else { throw ShelfError.archiveFolderMissing }
        return archiveURL
    }

    func stopAccess() {
        if accessingArchive, let archiveURL {
            archiveURL.stopAccessingSecurityScopedResource()
            accessingArchive = false
        }
    }
}
