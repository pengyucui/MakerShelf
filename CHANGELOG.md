# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，并使用[语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 计划

- 完善签名、公证和自动化发布流程。
- 继续提高 MakerWorld 接口变化时的兼容性与错误提示。

## [1.0] - 2026-09-22

### 新增

- 原生 SwiftUI macOS 模型库、下载任务和设置页面。
- MakerWorld 中文站与国际站网页登录、当前账号收藏和发布内容导入。
- 指定作者用户名、数字 UID 和主页链接解析，公开发布模型分页预览。
- 单模型链接导入、文件、介绍与展示图片完整归档。
- 本地模型创建、编辑、封面管理和文件快照归档。
- Native Glass 界面、统一尺寸卡片、网格与列表视图。

### 修复

- 修复作者公开列表错误复用网页登录令牌的问题。
- 修复国际站主页链接被默认中文站拒绝的问题。
- 修复模型图片比例不同导致卡片尺寸不一致的问题。
- 将钥匙串读取改为联网操作时按需恢复。

[未发布]: https://github.com/pengyucui/MakerShelf/compare/v1.0...HEAD
[1.0]: https://github.com/pengyucui/MakerShelf/releases/tag/v1.0
