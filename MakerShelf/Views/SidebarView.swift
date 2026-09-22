import SwiftUI

@MainActor
struct SidebarView: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cube.transparent").font(.system(size: 21, weight: .light))
                    .foregroundStyle(.white).frame(width: 36, height: 36)
                    .background(ShelfTheme.green.gradient, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: ShelfTheme.green.opacity(0.2), radius: 7, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MakerShelf").font(.system(size: 15, weight: .semibold))
                    Text("本地模型馆").font(.system(size: 9)).foregroundStyle(ShelfTheme.muted)
                }
            }.padding(.horizontal, 7).padding(.bottom, 25)
            Text("工作空间").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(ShelfTheme.muted).padding(.horizontal, 10).padding(.bottom, 9)
            VStack(spacing: 5) {
                ForEach(AppSection.allCases) { section in
                    Button { app.section = section } label: {
                        HStack(spacing: 11) {
                            Image(systemName: section.symbol).font(.system(size: 15)).frame(width: 20)
                            Text(section.rawValue).font(.system(size: 13, weight: app.section == section ? .semibold : .regular))
                            Spacer()
                            if section == .library {
                                Text(app.library.statistics.total, format: .number).font(.system(size: 11)).monospacedDigit()
                            } else if section == .downloads && app.downloads.pendingCount > 0 {
                                Text(app.downloads.pendingCount, format: .number).font(.system(size: 11)).monospacedDigit()
                            }
                        }.padding(.horizontal, 11).padding(.vertical, 10)
                            .foregroundStyle(app.section == section ? ShelfTheme.green : ShelfTheme.muted)
                            .background(app.section == section ? ShelfTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(app.section == section ? .isSelected : [])
                }
            }
            Text("来源").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(ShelfTheme.muted)
                .padding(.horizontal, 10).padding(.top, 26).padding(.bottom, 9)
            VStack(spacing: 6) {
                sourceRow(.china, title: "中文站",
                          subtitle: app.sessions.hasLoaded(.china)
                            ? (app.sessions.isConnected(.china) ? "已连接 · \(app.sessions.displayName(.china))" : app.sessions.displayName(.china))
                            : "按需读取登录状态",
                          dot: ShelfTheme.green)
                sourceRow(.international, title: "国际站",
                          subtitle: app.sessions.hasLoaded(.international)
                            ? (app.sessions.isConnected(.international) ? "已连接 · \(app.sessions.displayName(.international))" : app.sessions.displayName(.international))
                            : "按需读取登录状态",
                          dot: .blue.opacity(0.7))
                sourceRow(.local, title: "本地模型",
                          subtitle: "\(app.library.statistics.localCount) 个模型",
                          dot: .orange.opacity(0.8))
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "externaldrive.fill").foregroundStyle(ShelfTheme.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地资料库").font(.system(size: 11, weight: .semibold))
                        Text(storageLabel)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ShelfTheme.green)
                        Text("模型、介绍与图片同步归档").font(.system(size: 9)).foregroundStyle(ShelfTheme.muted)
                    }
                }
                ProgressView(value: min(app.library.statistics.storedMB / 1_024, 1))
                    .tint(ShelfTheme.green)
                    .padding(.top, 18)
            }
            .padding(13)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 16)
        }.padding(.horizontal, 14).padding(.top, 18)
            .frame(width: 236).background(.ultraThinMaterial)
            .overlay(alignment: .trailing) { Rectangle().fill(ShelfTheme.line).frame(width: 1) }
    }

    private var storageLabel: String {
        let mb = app.library.statistics.storedMB
        if mb >= 1_024 { return String(format: "%.1f GB", mb / 1_024) }
        return String(format: "%.1f MB", mb)
    }

    private func sourceRow(_ source: LibrarySource, title: String, subtitle: String, dot: Color) -> some View {
        let selected = app.library.query.source == source
        return Button {
            app.section = .library
            app.library.query.source = selected ? nil : source
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(dot).frame(width: 7, height: 7).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(selected ? ShelfTheme.selection : ShelfTheme.card.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? ShelfTheme.green.opacity(0.28) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
