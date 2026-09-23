# 参与贡献

感谢你改进 MakerShelf。提交代码前，请先搜索现有 Issue，避免重复讨论同一个问题。较大的功能、数据结构调整或站点接口改造，建议先创建功能建议并说明使用场景。

## 开发环境

- macOS 14 或更新版本
- Xcode 15 或更新版本
- SwiftUI、Foundation、AppKit、Observation
- 内置本地 Swift Package：`ThirdParty/libwebp`，包含源码与许可，无需在线拉取

用 Xcode 打开 `MakerShelf.xcodeproj`，选择共享 Scheme `MakerShelf` 和运行目标 `My Mac`。

## 分支与提交

1. 从 `main` 创建短期功能分支，例如 `feature/import-author-models` 或 `fix/session-restore`。
2. 一次提交只解决一个清晰问题，提交信息使用祈使句，例如 `修复作者主页站点识别`。
3. 不要提交 `build/`、`dist/`、DerivedData、个人 Xcode 状态、登录 Cookie、令牌或本地模型归档。
4. 修改用户可见行为时，同步更新 README、`docs/功能梳理.md`和 `CHANGELOG.md` 的“未发布”部分。

## 公开文件范围

`docs/` 仅提交 `发布流程.md` 和 `功能梳理.md`。其他内部资料由 `.gitignore` 排除，不要强制加入。Release 说明维护在 `.github/release-notes/`，应用运行资源及第三方源码、许可继续随仓库分发。

## 代码约定

- 保持 SwiftUI 视图轻量；文件读取、网络请求和大集合处理放在 Store、Service 或独立 actor 中。
- 新增并发代码时明确主 actor 与后台执行边界，支持取消并避免重复请求。
- 网络适配必须保留中文站与国际站隔离，不记录 Cookie、Authorization 或个人资料响应。
- 注释用于解释约束、异常分支和站点兼容原因，使用中文，避免复述代码。
- 不绕过 MakerWorld 的付费、积分、地区、版权或访问控制限制。

## Pull Request

PR 说明应包括：问题、最终行为、界面影响、验证方式、已知限制。涉及界面时附截图；涉及站点接口时说明使用的公开页面和失败降级方式，但不得粘贴真实登录凭据或完整响应。

提交贡献即表示你同意按仓库的 [Apache License 2.0](LICENSE) 授权你的贡献，并遵守 [行为准则](CODE_OF_CONDUCT.md)。
