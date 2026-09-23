import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// 用户配置在每次预览开始时取快照；范围收紧可避免异常偏好使缓存与渲染失控。
struct STLPreviewOptions: Sendable {
    static let pixelKey = "stlPreviewPixelBudget"
    static let timeoutKey = "stlPreviewTimeoutSeconds"
    static let defaults = Self(pixelBudget: 128_000_000, timeoutSeconds: 120)

    let pixelBudget: Int
    let timeoutSeconds: Int

    var cacheKey: String { "\(MeshPreviewRenderer.cacheVersion):\(pixelBudget):\(timeoutSeconds)" }

    static func current(_ store: UserDefaults = .standard) -> Self {
        func number(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
            guard store.object(forKey: key) != nil else { return fallback }
            return min(range.upperBound, max(range.lowerBound, store.integer(forKey: key)))
        }
        return Self(pixelBudget: number(pixelKey, fallback: defaults.pixelBudget, range: 16_000_000...256_000_000),
                    timeoutSeconds: number(timeoutKey, fallback: defaults.timeoutSeconds, range: 30...600))
    }
}

/// 二进制和 ASCII STL 均按块重放；完整绘制网格，不抽面，也不将整份模型留在内存。
/// 预览 actor 串行调用解析器，来源文件不被修改。
enum STLPreview {
    private static let chunkBytes = 256 * 1_024
    private static let maxLineBytes = 64 * 1_024

    enum Failure: LocalizedError {
        case malformed, empty, lineTooLong, timedOut
        var errorDescription: String? {
            switch self {
            case .malformed: return "STL 数据不完整，或包含无效坐标。"
            case .empty: return "STL 没有可显示的三角面。"
            case .lineTooLong: return "STL 文本行超过 64 KiB，无法安全解析。"
            case .timedOut: return "STL 预览超过设置中的最长处理时间；可调高上限后重试。"
            }
        }
    }

    static func imageData(from url: URL, options: STLPreviewOptions = .current()) throws -> Data {
        try Task.checkCancellation()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw Failure.malformed }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard size > 0 else { throw Failure.empty }
        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(options.timeoutSeconds))
        let header: Data
        if size >= 84 {
            header = try readExactly(handle, count: 84)
        } else {
            header = Data()
        }
        // 文件头只识别一次；后续扫描通过同一个句柄重放，内存只保留当前数据块。
        let binaryCount = header.count == 84 && 84 + UInt64(word(header, 80)) * 50 == size
            ? Int(word(header, 80)) : nil
        func forEachTriangle(_ visit: (PreviewTriangle) throws -> Void) throws {
            if let binaryCount {
                try handle.seek(toOffset: 84)
                try scanBinary(handle, count: binaryCount, deadline: deadline, visit: visit)
            } else {
                try handle.seek(toOffset: 0)
                try scanASCII(handle, deadline: deadline, visit: visit)
            }
        }
        var count = 0
        var bounds: MeshPreviewBounds?
        try forEachTriangle { triangle in
            count += 1
            var box = bounds ?? MeshPreviewBounds(lower: triangle.a, upper: triangle.a)
            box.lower = simd_min(box.lower, simd_min(triangle.a, simd_min(triangle.b, triangle.c)))
            box.upper = simd_max(box.upper, simd_max(triangle.a, simd_max(triangle.b, triangle.c)))
            bounds = box
        }
        guard count > 0, let bounds else { throw Failure.empty }
        let scanMillis = Int(Date().timeIntervalSince(started) * 1_000)
        let image = try MeshPreviewRenderer.render(bounds: bounds, pixelBudget: options.pixelBudget,
                                                    deadline: deadline, forEachTriangle: forEachTriangle)
        // 多次扫描必须对应同一份文件；外部程序改写时丢弃结果，避免缓存混合版本。
        var refreshedURL = url
        refreshedURL.removeAllCachedResourceValues()
        let latest = try refreshedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard values.fileSize == latest.fileSize,
              values.contentModificationDate == latest.contentModificationDate else { throw Failure.malformed }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        AppLog.write(.info, .preview, "STL 完整网格预览完成",
                     detail: "文件：\(url.lastPathComponent)；大小：\(size) B；总面数：\(count)；读取：\(scanMillis) ms；总耗时：\(elapsed) ms；设置：\(options.cacheKey)")
        return image
    }

    private static func scanBinary(_ handle: FileHandle, count: Int, deadline: Date, visit: (PreviewTriangle) throws -> Void) throws {
        guard count > 0 else { throw Failure.empty }
        let facetsPerChunk = max(1, chunkBytes / 50)
        var completed = 0
        while completed < count {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure.timedOut }
            let batchCount = min(facetsPerChunk, count - completed)
            let bytes = try readExactly(handle, count: batchCount * 50)
            for item in 0..<batchCount {
                if item % 1_024 == 0 {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw Failure.timedOut }
                }
                let offset = item * 50 + 12
                func vertex(_ start: Int) throws -> SIMD3<Double> {
                    let point = SIMD3(Double(Float(bitPattern: word(bytes, start))),
                                      Double(Float(bitPattern: word(bytes, start + 4))),
                                      Double(Float(bitPattern: word(bytes, start + 8))))
                    guard valid(point) else { throw Failure.malformed }
                    return point
                }
                try visit(PreviewTriangle(a: try vertex(offset), b: try vertex(offset + 12),
                                          c: try vertex(offset + 24)))
            }
            completed += batchCount
        }
    }

    private static func scanASCII(_ handle: FileHandle, deadline: Date, visit: (PreviewTriangle) throws -> Void) throws {
        var parser = ASCIIFacets()
        try forEachLine(handle, deadline: deadline) { line in
            if let triangle = try parser.consume(line) { try visit(triangle) }
        }
        try parser.finish()
    }

    private struct ASCIIFacets {
        private var vertices: [SIMD3<Double>] = []
        private var inFacet = false
        private var inLoop = false
        private var sawSolid = false

        mutating func consume(_ text: String) throws -> PreviewTriangle? {
            let line = text.split(whereSeparator: { $0.isWhitespace })
            guard let command = line.first?.lowercased() else { return nil }
            switch command {
            case "solid": sawSolid = true
            case "endsolid": guard !inFacet else { throw Failure.malformed }
            case "facet":
                guard sawSolid, !inFacet else { throw Failure.malformed }
                inFacet = true
                vertices.removeAll(keepingCapacity: true)
            case "outer":
                guard inFacet, !inLoop, line.count == 2, line[1].lowercased() == "loop" else { throw Failure.malformed }
                inLoop = true
            case "vertex":
                guard inLoop, vertices.count < 3, line.count == 4,
                      let x = Double(line[1]), let y = Double(line[2]), let z = Double(line[3]) else { throw Failure.malformed }
                let point = SIMD3(x, y, z)
                guard valid(point) else { throw Failure.malformed }
                vertices.append(point)
            case "endloop":
                guard inLoop, vertices.count == 3 else { throw Failure.malformed }
                inLoop = false
            case "endfacet":
                guard inFacet, !inLoop, vertices.count == 3 else { throw Failure.malformed }
                inFacet = false
                return PreviewTriangle(a: vertices[0], b: vertices[1], c: vertices[2])
            default: throw Failure.malformed
            }
            return nil
        }

        func finish() throws {
            guard !inFacet, !inLoop else { throw Failure.malformed }
        }
    }

    /// 只保留当前行；CRLF、单独 CR 和 LF 均能跨读取块正确分行。
    private static func forEachLine(_ handle: FileHandle, deadline: Date,
                                    _ consume: (String) throws -> Void) throws {
        var pending = Data()
        var skipLF = false
        var firstLine = true
        func emit() throws {
            guard let raw = String(data: pending, encoding: .utf8) else { throw Failure.malformed }
            let line = firstLine && raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
            firstLine = false
            try consume(line)
            pending.removeAll(keepingCapacity: true)
        }
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure.timedOut }
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            var segmentStart = chunk.startIndex
            for index in chunk.indices {
                let byte = chunk[index]
                if byte == 10 || byte == 13 {
                    pending.append(contentsOf: chunk[segmentStart..<index])
                    guard pending.count <= maxLineBytes else { throw Failure.lineTooLong }
                    if byte == 10 && skipLF && pending.isEmpty {
                        skipLF = false
                    } else {
                        try emit()
                        skipLF = byte == 13
                    }
                    segmentStart = chunk.index(after: index)
                } else {
                    skipLF = false
                }
            }
            pending.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
            guard pending.count <= maxLineBytes else { throw Failure.lineTooLong }
        }
        if !pending.isEmpty { try emit() }
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw Failure.malformed
            }
            result.append(chunk)
        }
        return result
    }

    private static func valid(_ point: SIMD3<Double>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
            && abs(point.x) < 1e100 && abs(point.y) < 1e100 && abs(point.z) < 1e100
    }

    private static func word(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

/// STL 与 OBJ 共用完整网格渲染；STL 通过分块重放供给三角面，OBJ 仍使用自己的文件和面数限制。
struct PreviewTriangle {
    let a: SIMD3<Double>
    let b: SIMD3<Double>
    let c: SIMD3<Double>
}

struct MeshPreviewBounds {
    var lower: SIMD3<Double>
    var upper: SIMD3<Double>
}

enum MeshPreviewRenderer {
    // 渲染算法升级同时更新 STL / OBJ 缓存身份，避免沿用旧的抽面图片。
    static let cacheVersion = "solid-mesh-v3"

    enum Failure: LocalizedError {
        case empty, renderLimit, timedOut
        var errorDescription: String? {
            switch self {
            case .empty: return "模型网格没有可显示的三角面。"
            case .renderLimit: return "完整模型超出预览像素预算，请提高预算后重试。"
            case .timedOut: return "静态预览超过设置中的最长处理时间。"
            }
        }
    }

    /// OBJ 复用同一渲染入口；STL 直接传入分块重放函数，无需分配完整面数组。
    static func render(_ triangles: [PreviewTriangle]) throws -> Data {
        var bounds = MeshPreviewBounds(lower: SIMD3<Double>(repeating: .infinity),
                                       upper: SIMD3<Double>(repeating: -.infinity))
        for triangle in triangles {
            try Task.checkCancellation()
            bounds.lower = simd_min(bounds.lower, simd_min(triangle.a, simd_min(triangle.b, triangle.c)))
            bounds.upper = simd_max(bounds.upper, simd_max(triangle.a, simd_max(triangle.b, triangle.c)))
        }
        return try render(bounds: bounds, forEachTriangle: { visit in
            for triangle in triangles { try visit(triangle) }
        })
    }

    /// 分别统计各分辨率的真实候选像素量，再完整绘制；预算不足时只降低分辨率，绝不跳过三角面。
    /// 所有重放同步完成，读取、预算估算与绘制共用取消状态和同一个截止时间。
    static func render(bounds: MeshPreviewBounds, pixelBudget: Int = 128_000_000,
                       deadline: Date? = nil,
                       forEachTriangle: (_ visit: (PreviewTriangle) throws -> Void) throws -> Void) throws -> Data {
        func check() throws {
            try Task.checkCancellation()
            if let deadline, Date() >= deadline { throw Failure.timedOut }
        }
        try check()
        let extent = bounds.upper - bounds.lower
        let size = max(extent.x, max(extent.y, extent.z))
        guard size.isFinite, size > 0 else { throw Failure.empty }
        let center = bounds.lower + extent / 2
        func project(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let q = (p - center) / size
            return SIMD3((q.x - q.y) * sqrt(0.5), q.z * sqrt(2.0 / 3) - (q.x + q.y) * sqrt(1.0 / 6),
                         (q.x + q.y + q.z) / sqrt(3))
        }
        // 先测量真实投影范围，细长或斜置模型也能居中并充分利用画面。
        var projectedLow = SIMD2<Double>(repeating: .infinity)
        var projectedHigh = SIMD2<Double>(repeating: -.infinity)
        try forEachTriangle { triangle in
            try check()
            for point in [triangle.a, triangle.b, triangle.c] {
                let q = project(point)
                let xy = SIMD2(q.x, q.y)
                projectedLow = simd_min(projectedLow, xy)
                projectedHigh = simd_max(projectedHigh, xy)
            }
        }
        let projectedExtent = projectedHigh - projectedLow
        let projectedCenter = (projectedLow + projectedHigh) / 2
        guard projectedExtent.x.isFinite, projectedExtent.y.isFinite,
              max(projectedExtent.x, projectedExtent.y) > 0 else { throw Failure.empty }
        func screen(_ p: SIMD3<Double>, width: Int) -> SIMD3<Double> {
            let height = width * 3 / 4
            let scale = min(Double(width) * 0.84 / max(projectedExtent.x, 1e-12),
                            Double(height) * 0.84 / max(projectedExtent.y, 1e-12))
            let q = project(p)
            return SIMD3(Double(width) / 2 + (q.x - projectedCenter.x) * scale,
                         Double(height) / 2 - (q.y - projectedCenter.y) * scale, q.z)
        }
        func box(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, width: Int)
            -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard area.isFinite, abs(area) > 1e-10 else { return nil }
            // 在转整数之前裁剪浮点范围，防止源文件在扫描间被改写后产生越界坐标。
            let height = width * 3 / 4
            let minX = Int(max(0, min(Double(width), floor(min(a.x, min(b.x, c.x))))))
            let maxX = Int(max(-1, min(Double(width - 1), ceil(max(a.x, max(b.x, c.x))))))
            let minY = Int(max(0, min(Double(height), floor(min(a.y, min(b.y, c.y))))))
            let maxY = Int(max(-1, min(Double(height - 1), ceil(max(a.y, max(b.y, c.y))))))
            guard minX <= maxX, minY <= maxY else { return nil }
            return (minX, maxX, minY, maxY)
        }
        // 优先以两倍尺寸绘制后缩小，平滑轮廓；复杂模型依预算逐级降低尺寸。
        let widths = [1920, 960, 640, 320]
        var costs = [Int](repeating: 0, count: widths.count)
        try forEachTriangle { triangle in
            try check()
            for (index, width) in widths.enumerated() where costs[index] <= pixelBudget {
                let a = screen(triangle.a, width: width), b = screen(triangle.b, width: width)
                let c = screen(triangle.c, width: width)
                if let box = box(a, b, c, width: width) {
                    costs[index] += (box.maxX - box.minX + 1) * (box.maxY - box.minY + 1)
                }
            }
        }
        guard let level = costs.firstIndex(where: { $0 > 0 && $0 <= pixelBudget }) else { throw Failure.renderLimit }
        let width = widths[level], height = width * 3 / 4
        AppLog.write(.info, .preview, "完整网格预览分辨率已确定",
                     detail: "绘制：\(width) × \(height)；候选像素：\(costs[level])；预算：\(pixelBudget)；抗锯齿：\(level == 0 ? "两倍超采样" : "标准")")
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var depth = [Double](repeating: -.infinity, count: width * height)
        // 使用轻微渐变的中性背景，避免纯白背景与高光混在一起。
        for y in 0..<height {
            try check()
            let tone = UInt8(248 - 10 * Double(y) / Double(max(1, height - 1)))
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = tone
                pixels[offset + 1] = tone
                pixels[offset + 2] = min(255, tone + 2)
            }
        }
        let view = simd_normalize(SIMD3<Double>(1, 1, 1))
        let keyLight = simd_normalize(SIMD3<Double>(-0.3, 0.7, 1.4))
        let fillLight = simd_normalize(SIMD3<Double>(1, -0.3, 0.5))
        let halfLight = simd_normalize(keyLight + view)
        var painted = false
        var work = 0
        try forEachTriangle { triangle in
            try check()
            let a = screen(triangle.a, width: width), b = screen(triangle.b, width: width)
            let c = screen(triangle.c, width: width)
            guard let box = box(a, b, c, width: width) else { return }
            work += (box.maxX - box.minX + 1) * (box.maxY - box.minY + 1)
            // 重放期间若源文件被外部改写，仍不能突破已经约定的绘制预算。
            guard work <= pixelBudget else { throw Failure.renderLimit }
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            let rawNormal = simd_cross((triangle.b - triangle.a) / size, (triangle.c - triangle.a) / size)
            let length = simd_length(rawNormal)
            guard length > 0 else { return }
            var normal = rawNormal / length
            // 按观察方向统一双面光照，兼容 STL 面绕序不一致，同时保留棱角明暗。
            if simd_dot(normal, view) < 0 { normal = -normal }
            let shade = 0.28 + 0.52 * max(0, simd_dot(normal, keyLight))
                + 0.20 * max(0, simd_dot(normal, fillLight))
            let highlight = 24 * pow(max(0, simd_dot(normal, halfLight)), 24)
            let red = UInt8(min(255, 166 * shade + highlight))
            let green = UInt8(min(255, 192 * shade + highlight))
            let blue = UInt8(min(255, 211 * shade + highlight))
            for y in box.minY...box.maxY {
                if y % 32 == 0 { try check() }
                for x in box.minX...box.maxX {
                    let px = Double(x) + 0.5 - a.x, py = Double(y) + 0.5 - a.y
                    let u = (px * (c.y - a.y) - py * (c.x - a.x)) / area
                    let v = ((b.x - a.x) * py - (b.y - a.y) * px) / area
                    guard u >= -1e-9, v >= -1e-9, u + v <= 1 + 1e-9 else { continue }
                    let z = a.z + u * (b.z - a.z) + v * (c.z - a.z)
                    let offset = y * width + x
                    guard z > depth[offset] else { continue }
                    depth[offset] = z
                    pixels[offset * 4] = red
                    pixels[offset * 4 + 1] = green
                    pixels[offset * 4 + 2] = blue
                    painted = true
                }
            }
        }
        guard painted else { throw Failure.empty }
        try check()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ShelfError.invalidImage
        }
        var outputImage = image
        if level == 0 {
            // 1920 × 1440 缩为 960 × 720，使文件行和放大预览都减少边缘锯齿。
            guard let context = CGContext(data: nil, width: 960, height: 720, bitsPerComponent: 8,
                                          bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ShelfError.invalidImage
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 960, height: 720))
            guard let reduced = context.makeImage() else { throw ShelfError.invalidImage }
            outputImage = reduced
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ShelfError.invalidImage
        }
        CGImageDestinationAddImage(destination, outputImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShelfError.invalidImage }
        try check()
        return output as Data
    }
}
