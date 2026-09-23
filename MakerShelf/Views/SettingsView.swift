import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var preferences: PreferencesStore
    let sessions: SessionStore
    @Binding var tab: SettingsTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "设置", subtitle: "管理站点登录，以及本地存储与下载偏好。")
                Picker("设置分类", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 270).labelsHidden()
                if tab == .accounts {
                    accounts.task { await sessions.restoreStoredSessions() }
                } else {
                    storage
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 24)
            .frame(maxWidth: 1_050, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 24) {
            NoticeBanner(text: "中文站与国际站分别登录。连接账号后，可以导入自己的收藏与作品，并下载对应站点的模型。")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 480), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(MakerSite.allCases) { site in
                    AccountCard(site: site, state: sessions.states[site] ?? .disconnected,
                                detail: sessions.displayName(site),
                                warning: sessions.keychainWarnings[site],
                                retryPersistence: sessions.canRetryPersistence(site) ? { sessions.retryPersistence(site) } : nil) {
                        if sessions.isConnected(site) {
                            sessions.disconnect(site)
                        } else {
                            LoginPresenter.open(site: site, sessions: sessions, onConnected: {})
                        }
                    }
                }
            }
            GlassPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Label("账号与内容来源", systemImage: "person.2").font(.system(size: 12, weight: .semibold))
                    Text("下载使用对应站点的登录状态。当前账号可读取收藏与发布内容；指定作者可按用户名、用户 ID 或主页链接读取公开发布模型。")
                        .font(.system(size: 12)).foregroundStyle(ShelfTheme.muted).lineSpacing(4)
                    Text("登录状态保存在 macOS 钥匙串中。中文站和国际站各有一条旧记录，第一次各确认一次，用来复制到当前 App 自己的记录。确认后同一安装包不再重复授权。重新打包会改变临时签名，可能再各确认一次。")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineSpacing(4)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 23) {
            GlassPanel {
              VStack(alignment: .leading, spacing: 18) {
                Label("本地存储", systemImage: "folder").font(.system(size: 14, weight: .semibold))
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("模型库位置").font(.system(size: 13))
                        Text(preferences.archivePath).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    Button("选择目录") { preferences.selectArchiveFolder() }.buttonStyle(QuietButtonStyle())
                }
                if let error = preferences.errorMessage { NoticeBanner(text: error, symbol: "exclamationmark.triangle") }
                Text("目录通过系统授权选择。下载开始后，模型文件、介绍和图片会写入该目录。")
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
              }
            }
            GlassPanel {
              VStack(alignment: .leading, spacing: 20) {
                Label("下载偏好", systemImage: "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("完整归档").font(.system(size: 13))
                        Text("固定包含模型、介绍和图片，并保留作者与来源。").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    Label("默认包含", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(ShelfTheme.green)
                }
                Divider()
                Picker("首选文件格式", selection: $preferences.preferredFormat) {
                    ForEach(["全部可用格式", "优先 3MF", "优先 STL"], id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 380)
                Text("优先 3MF 时下载打印配置；优先 STL 时尽量取原始模型文件，没有则回退到 3MF。")
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                Picker("并行任务数", selection: $preferences.maxConcurrentDownloads) {
                    ForEach(1...3, id: \.self) { Text("\($0) 个任务").tag($0) }
                }.frame(maxWidth: 380)
                Text("降低上限后，新任务等待已有任务完成再启动。").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
              }
            }
            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("STL 静态预览", systemImage: "cube.transparent")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button("恢复默认") { preferences.resetSTLPreviewOptions() }
                            .buttonStyle(QuietButtonStyle())
                    }
                    Divider()
                    Text("大文件会分块读取并绘制完整网格。预算控制图片清晰度和最长耗时，不会通过删除三角面来加速。原始模型文件不受影响。")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                    Picker("候选像素检查预算", selection: $preferences.stlPreviewPixelBudget) {
                        ForEach(Array(stride(from: 16_000_000, through: 256_000_000, by: 16_000_000)), id: \.self) { value in
                            Text("最多 \(value / 10_000) 万次").tag(value)
                        }
                    }.frame(maxWidth: 380)
                    Text("优先生成 960 × 720 图片，预算充足时使用抗锯齿；复杂模型会降低分辨率。预算不足以绘制完整模型时会提示重试，不会显示缺面的模型。")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                    Picker("最长处理时间", selection: $preferences.stlPreviewTimeoutSeconds) {
                        ForEach(Array(stride(from: 30, through: 600, by: 30)), id: \.self) { value in
                            Text("\(value) 秒").tag(value)
                        }
                    }.frame(maxWidth: 380)
                    Text("超时会显示格式占位并写入运行日志。修改后对下一次预览生效；已有图片可点“按当前设置重新生成”，失败时可点“重试预览”。默认值尚需结合真实大模型的内存和耗时再校准。")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Label("偏好自动保存在本机，无需再次点击保存。", systemImage: "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        }
    }
}

@MainActor
private struct AccountCard: View {
    let site: MakerSite
    let state: ConnectionState
    let detail: String
    let warning: String?
    let retryPersistence: (() -> Void)?
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("M").font(.system(size: 28, weight: .bold, design: .rounded)).italic()
                    .foregroundStyle(site == .china ? ShelfTheme.green : .blue.opacity(0.6))
                    .frame(width: 48, height: 48).background(ShelfTheme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                Text(statusText).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.isConnected ? ShelfTheme.green : ShelfTheme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background((state.isConnected ? ShelfTheme.green : ShelfTheme.muted).opacity(0.1), in: Capsule())
            }
            Text("MakerWorld \(site.title)").font(.system(size: 16, weight: .semibold))
            Text(site.domain).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
            Divider()
            Label(state.isConnected ? detail : "连接后可导入该站点的收藏", systemImage: "person.crop.circle")
                .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineLimit(2)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let retryPersistence {
                Button("重新保存登录状态", action: retryPersistence).buttonStyle(QuietButtonStyle())
            }
            Button(state.isConnected ? "断开连接" : "打开登录页", action: action).buttonStyle(QuietButtonStyle())
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .shelfSurface()
    }

    private var statusText: String {
        switch state {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .expired: return "已过期"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
        }
    }
}
