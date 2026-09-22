import Foundation
import ImageIO
import CoreGraphics

/// CGImage 在创建后只读；跨任务传递不会共享可变绘图上下文。
final class Thumbnail: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
    var byteCost: Int { image.bytesPerRow * image.height }
}

/// 队列只负责图片 I/O 和缩略解码，最多同时解码两张，避免快速滚动触发并发峰值。
private final class ThumbnailDecoder: @unchecked Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MakerShelf.ThumbnailDecoder"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func decode(url: URL, pixels: Int) async throws -> Thumbnail {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                autoreleasepool {
                    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                        continuation.resume(throwing: ShelfError.invalidImage)
                        return
                    }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                        continuation.resume(throwing: ShelfError.invalidImage)
                        return
                    }
                    continuation.resume(returning: Thumbnail(image))
                }
            }
        }
    }

    func decode(data: Data, pixels: Int) async throws -> Thumbnail {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                autoreleasepool {
                    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                        continuation.resume(throwing: ShelfError.invalidImage)
                        return
                    }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                        continuation.resume(throwing: ShelfError.invalidImage)
                        return
                    }
                    continuation.resume(returning: Thumbnail(image))
                }
            }
        }
    }
}

actor ImagePipeline {
    static let shared = ImagePipeline()
    private let cache = NSCache<NSString, Thumbnail>()
    private let decoder = ThumbnailDecoder()
    private var inFlight: [String: Task<Thumbnail, Error>] = [:]

    init() {
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 128
    }

    func thumbnail(named name: String, pixels: Int) async throws -> Thumbnail {
        try await thumbnail(ArtworkSource.bundled(name), pixels: pixels)
    }

    func thumbnail(_ source: ArtworkSource, pixels: Int) async throws -> Thumbnail {
        let bucket = [160, 640, 1_280].first(where: { $0 >= pixels }) ?? 1_280
        let key = cacheKey(source, bucket: bucket)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let pending = inFlight[key] { return try await pending.value }
        let decoder = decoder
        let task = Task<Thumbnail, Error> {
            switch source {
            case .bundled(let name):
                guard !name.isEmpty,
                      let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Artwork") else {
                    throw ShelfError.resourceMissing
                }
                return try await decoder.decode(url: url, pixels: bucket)
            case .file(let url):
                // fileImporter 返回安全作用域 URL；解码期间临时访问，结束后立即释放。
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try await decoder.decode(url: url, pixels: bucket)
            case .remote(let url):
                var request = URLRequest(url: url)
                request.setValue("https://makerworld.com/", forHTTPHeaderField: "Referer")
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ShelfError.invalidImage
                }
                return try await decoder.decode(data: data, pixels: bucket)
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let thumbnail = try await task.value
        cache.setObject(thumbnail, forKey: key as NSString, cost: thumbnail.byteCost)
        return thumbnail
    }

    func clearCache() { cache.removeAllObjects() }

    private func cacheKey(_ source: ArtworkSource, bucket: Int) -> String {
        switch source {
        case .bundled(let name): return "bundle:\(name):\(bucket)"
        case .file(let url): return "file:\(url.path):\(bucket)"
        case .remote(let url): return "remote:\(url.absoluteString):\(bucket)"
        }
    }
}
