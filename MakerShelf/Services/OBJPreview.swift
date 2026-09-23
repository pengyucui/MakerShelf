import Foundation
import simd

/// OBJ 只读取顶点和多边形面；材质、纹理和法线不影响单色静态预览。
/// 坐标索引支持正数与相对当前位置的负数，解析与渲染复用 STL 的资源限制。
enum OBJPreview {
    private static let maxFileBytes = 64 * 1_024 * 1_024
    private static let maxTriangles = 500_000
    private static let maxFaceVertices = 1_024

    enum Failure: LocalizedError {
        case tooLarge, malformed, empty, nonConvex
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "OBJ 超出静态预览限制（64 MiB、50 万三角面或单面 1,024 个顶点）。"
            case .malformed: return "OBJ 顶点或面索引无效。"
            case .empty: return "OBJ 没有可显示的多边形面。"
            case .nonConvex: return "OBJ 含有凹多边形面，当前静态预览需要先将它三角化。"
            }
        }
    }

    static func imageData(from url: URL) throws -> Data {
        try Task.checkCancellation()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw Failure.malformed }
        guard let size = values.fileSize, size <= maxFileBytes else { throw Failure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maxFileBytes + 1), !data.isEmpty else { throw Failure.empty }
        guard data.count <= maxFileBytes else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.malformed }

        var vertices: [SIMD3<Double>] = []
        var triangles: [PreviewTriangle] = []
        var start = text.first == "\u{FEFF}" ? text.index(after: text.startIndex) : text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            let end = text[start...].firstIndex(where: { $0.isNewline }) ?? text.endIndex
            let fields = text[start..<end].split(whereSeparator: { $0.isWhitespace })
            start = end == text.endIndex ? end : text.index(after: end)
            guard let command = fields.first else { continue }
            switch command {
            case "v":
                guard fields.count >= 4,
                      let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]) else {
                    throw Failure.malformed
                }
                let point = SIMD3(x, y, z)
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                      abs(x) < 1e100, abs(y) < 1e100, abs(z) < 1e100 else { throw Failure.malformed }
                vertices.append(point)
            case "f":
                let face = fields.dropFirst().prefix { !$0.hasPrefix("#") }
                guard face.count >= 3 else { throw Failure.malformed }
                guard face.count <= maxFaceVertices, triangles.count + face.count - 2 <= maxTriangles else {
                    throw Failure.tooLarge
                }
                var points: [SIMD3<Double>] = []
                points.reserveCapacity(face.count)
                for token in face {
                    let raw = token.split(separator: "/", omittingEmptySubsequences: false).first ?? ""
                    guard let number = Int(raw), number != 0 else { throw Failure.malformed }
                    let index = number > 0 ? number - 1 : vertices.count + number
                    guard vertices.indices.contains(index) else { throw Failure.malformed }
                    points.append(vertices[index])
                }
                guard isConvex(points) else { throw Failure.nonConvex }
                for index in 1..<(points.count - 1) {
                    triangles.append(PreviewTriangle(a: points[0], b: points[index], c: points[index + 1]))
                }
            default: break // vt、vn、材质、分组等不影响单色几何预览。
            }
        }
        guard !triangles.isEmpty else { throw Failure.empty }
        return try MeshPreviewRenderer.render(triangles)
    }

    /// 仅对凸面做扇形三角化；凹面直接报错，避免生成看似成功但缺面或交叠的图片。
    private static func isConvex(_ points: [SIMD3<Double>]) -> Bool {
        guard points.count > 3 else { return true }
        var normal = SIMD3<Double>(repeating: 0)
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            normal += SIMD3((a.y - b.y) * (a.z + b.z),
                            (a.z - b.z) * (a.x + b.x),
                            (a.x - b.x) * (a.y + b.y))
        }
        let axis: Int
        if abs(normal.x) >= abs(normal.y), abs(normal.x) >= abs(normal.z) { axis = 0 }
        else if abs(normal.y) >= abs(normal.z) { axis = 1 }
        else { axis = 2 }
        func projected(_ p: SIMD3<Double>) -> SIMD2<Double> {
            switch axis {
            case 0: return SIMD2(p.y, p.z)
            case 1: return SIMD2(p.x, p.z)
            default: return SIMD2(p.x, p.y)
            }
        }
        var direction = 0
        for index in points.indices {
            let a = projected(points[index])
            let b = projected(points[(index + 1) % points.count])
            let c = projected(points[(index + 2) % points.count])
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-12 { continue }
            let sign = cross > 0 ? 1 : -1
            if direction != 0, sign != direction { return false }
            direction = sign
        }
        return direction != 0
    }
}
