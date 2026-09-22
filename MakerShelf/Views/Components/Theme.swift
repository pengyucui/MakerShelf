import AppKit
import SwiftUI

/// 方案 A 的共享视觉语义，避免每个页面分别维护色值与间距。
enum AppVersion {
    static var label: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

enum ShelfTheme {
    // 使用系统语义色承接浅色与深色外观，玻璃材质仍保留统一的森林绿品牌色。
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let green = Color(hex: "326D50")
    static let selection = green.opacity(0.13)
    static let line = Color.primary.opacity(0.09)
    static let card = Color(nsColor: .controlBackgroundColor)
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 15).padding(.vertical, 11)
            .foregroundStyle(.white)
            .background(ShelfTheme.green.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: ShelfTheme.green.opacity(configuration.isPressed ? 0 : 0.16), radius: 5, y: 2)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(ShelfTheme.ink)
            .background(configuration.isPressed ? ShelfTheme.selection : ShelfTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ShelfTheme.line))
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
            .padding(13).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ShelfTheme.line))
    }
}

@MainActor
struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 27, weight: .semibold)).tracking(-0.5)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineSpacing(3)
        }
    }
}

@MainActor
struct StatusLabel: View {
    let downloaded: Bool
    var demo = false
    var body: some View {
        Label(downloaded ? (demo ? "已归档 · 示例" : "已归档") : "未下载", systemImage: downloaded ? "checkmark" : "arrow.down.circle")
            .font(.system(size: 10)).foregroundStyle(downloaded ? ShelfTheme.green : ShelfTheme.muted)
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
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(ShelfTheme.green.opacity(0.72))
                .frame(width: 68, height: 68).background(ShelfTheme.selection, in: RoundedRectangle(cornerRadius: 18))
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(description).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
        }.padding(28).frame(maxWidth: .infinity, minHeight: 250)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ShelfTheme.line))
    }
}

/// 全局玻璃面板，统一主要页面的圆角、边框与轻阴影。
@MainActor
struct GlassPanel<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ShelfTheme.line))
            .shadow(color: ShelfTheme.ink.opacity(0.035), radius: 9, y: 4)
    }
}
