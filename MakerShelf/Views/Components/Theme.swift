import AppKit
import SwiftUI

enum AppVersion {
    static var label: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// 应用视觉语义。深墨色表达操作，绿色只表达成功状态；深色外观使用对应的语义色。
enum ShelfTheme {
    static let canvas = adaptive("F5F7FA", dark: "151920")
    static let sidebar = adaptive("F0F3F8", dark: "1A202A")
    static let ink = adaptive("111827", dark: "E8EDF5")
    static let muted = adaptive("68758C", dark: "A2AEC0")
    static let accent = adaptive("111827", dark: "DEE7F4")
    static let onAccent = adaptive("FFFFFF", dark: "17202E")
    static let green = adaptive("16865E", dark: "67D5AD")
    static let selection = adaptive("E8EDF4", dark: "303B4C")
    static let line = adaptive("E3E8F0", dark: "343E4D")
    static let card = adaptive("FFFFFF", dark: "212833")
    static let recessed = adaptive("F1F4F8", dark: "19212D")
    static let shadow = Color.black.opacity(0.045)

    private static func adaptive(_ light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let value = UInt32(hex, radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

/// 毛玻璃仅用于窗口边缘的大容器；尊重系统“减少透明度”，不在每个模型卡片上重复模糊。
struct ShelfChrome: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            ShelfTheme.sidebar
        } else {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(ShelfTheme.sidebar.opacity(0.45))
        }
    }
}

/// 统一白色表面、细边框与轻阴影，滚动内容使用实色以减少合成开销。
private struct ShelfSurface: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ShelfTheme.line.opacity(0.7)))
            .shadow(color: ShelfTheme.shadow, radius: 8, y: 3)
    }
}

extension View {
    func shelfSurface(radius: CGFloat = 16) -> some View {
        modifier(ShelfSurface(radius: radius))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 11)
            .foregroundStyle(ShelfTheme.onAccent)
            .background(ShelfTheme.accent.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .foregroundStyle(ShelfTheme.ink)
            .background(configuration.isPressed ? ShelfTheme.selection : ShelfTheme.card,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShelfTheme.line))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

@MainActor
struct NoticeBanner: View {
    let text: String
    var symbol = "info.circle"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
            .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
            .padding(13).background(ShelfTheme.recessed, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ShelfTheme.line))
    }
}

@MainActor
struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 27, weight: .semibold)).tracking(-0.5)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted).lineSpacing(3)
        }
    }
}

@MainActor
struct StatusLabel: View {
    let downloaded: Bool
    var demo = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(downloaded ? ShelfTheme.green : ShelfTheme.muted.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(downloaded ? (demo ? "已归档 · 示例" : "已归档") : "未下载")
        }
        .font(.system(size: 11))
        .foregroundStyle(ShelfTheme.muted)
    }
}

@MainActor
struct EmptyShelf: View {
    let title: String
    let description: String
    let symbol: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(ShelfTheme.ink)
                .frame(width: 68, height: 68).background(ShelfTheme.recessed, in: RoundedRectangle(cornerRadius: 18))
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(description).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
        }.padding(28).frame(maxWidth: .infinity, minHeight: 250)
            .shelfSurface()
    }
}

/// 沿用既有面板调用入口，内部统一改用 实色卡片，避免表单内多层毛玻璃。
@MainActor
struct GlassPanel<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content.padding(padding).shelfSurface()
    }
}
