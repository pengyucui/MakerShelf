import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import libwebp

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

    func thumbnail(_ source: ArtworkSource, pixels: Int, revision: String = "") async throws -> Thumbnail {
        // 展示图缩略条使用 320 档，避免约 80 点的小图占用 640 像素解码内存。
        let bucket = [160, 320, 640, 1_280].first(where: { $0 >= pixels }) ?? 1_280
        // 同一路径替换图片后按归档版本隔离缓存及在途请求，旧解码结果不会覆盖新版封面。
        let key = "\(cacheKey(source, bucket: bucket)):revision:\(revision)"
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
        let thumbnail: Thumbnail
        do { thumbnail = try await task.value }
        catch {
            if !(error is CancellationError), source != .bundled("") {
                let context: String
                switch source {
                case .bundled(let name): context = "应用资源：\(name)"
                case .file(let url): context = "文件：\(url.lastPathComponent)"
                case .remote(let url): context = "远程图片：\(url.host ?? "未知站点")"
                }
                AppLog.write(.warning, .image, "缩略图加载失败", detail: "\(context)\n\(AppLog.errorDescription(error))")
            }
            throw error
        }
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

/// 用 libwebp 把展示图收成最长边 1600、质量 75 的 WebP。动图只保留第一帧。
/// 编码失败时回退成 JPEG，避免一次库错误丢掉整张图。
enum DisplayImage {
    static let maxEdge = 1_600
    static let quality: Float = 75

    /// 后台只返回编码数据；调用方检查取消状态后才提交文件，避免暂停任务继续覆盖归档。
    struct Encoded: Sendable {
        let data: Data
        let fileExtension: String

        func write(to destination: URL) throws -> URL {
            try Task.checkCancellation()
            let output = destination.deletingPathExtension().appendingPathExtension(fileExtension)
            try data.write(to: output, options: .atomic)
            return output
        }
    }

    static func compressed(from source: URL) throws -> Encoded {
        try Task.checkCancellation()
        return try compressed(resizedImage(from: source))
    }

    static func compressed(data: Data) throws -> Encoded {
        try Task.checkCancellation()
        return try compressed(resizedImage(from: data))
    }

    private static func compressed(_ image: CGImage) throws -> Encoded {
        try Task.checkCancellation()
        if let encoded = encodeWebP(image, quality: quality) {
            try Task.checkCancellation()
            return Encoded(data: encoded, fileExtension: "webp")
        }
        return Encoded(data: try encodeJPEG(image), fileExtension: "jpg")
    }

    private static func resizedImage(from source: URL) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let input = CGImageSourceCreateWithURL(source as CFURL, options) else { throw ShelfError.invalidImage }
        return try resizedImage(input)
    }

    private static func resizedImage(from data: Data) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let input = CGImageSourceCreateWithData(data as CFData, options) else { throw ShelfError.invalidImage }
        return try resizedImage(input)
    }

    private static func resizedImage(_ input: CGImageSource) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let edge = max(width, height)
        let pixelLimit = edge > 0 ? min(edge, maxEdge) : maxEdge
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(input, 0, thumbOptions as CFDictionary) else {
            throw ShelfError.invalidImage
        }
        // WebP 分支直接在输出缓冲中合成白底，避免再创建一份同尺寸的中间位图。
        return decoded
    }

    private static func encodeWebP(_ image: CGImage, quality: Float) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 255, count: height * rowBytes)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        // CGContext 与 C 编码器只能在数组借用指针的有效期内使用这块 RGBA 内存。
        return pixels.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmap) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var output: UnsafeMutablePointer<UInt8>?
            let count = WebPEncodeRGBA(base, Int32(width), Int32(height), Int32(rowBytes), quality, &output)
            defer { if let output { WebPFree(output) } }
            guard count > 0, let output else { return nil }
            return Data(bytes: output, count: count)
        }
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let flattened = flatten(image),
              let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ShelfError.invalidImage
        }
        let compression = [kCGImageDestinationLossyCompressionQuality: quality / 100] as CFDictionary
        CGImageDestinationAddImage(output, flattened, compression)
        guard CGImageDestinationFinalize(output) else { throw ShelfError.invalidImage }
        return data as Data
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// 串行执行压缩，限制批量封面和下载图片的并发内存；调用者的取消状态会传入 actor 方法。
actor DisplayImageEncoder {
    static let shared = DisplayImageEncoder()

    func compress(from source: URL) throws -> DisplayImage.Encoded {
        try autoreleasepool { try DisplayImage.compressed(from: source) }
    }

    func compress(data: Data) throws -> DisplayImage.Encoded {
        try autoreleasepool { try DisplayImage.compressed(data: data) }
    }
}
