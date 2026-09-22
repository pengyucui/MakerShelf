# MakerShelf · MakerWorld 本地模型馆

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-111111.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138.svg)](https://www.swift.org/)
[![License](https://img.shields.io/github/license/pengyucui/MakerShelf)](LICENSE)
[![Release](https://img.shields.io/github/v/release/pengyucui/MakerShelf)](https://github.com/pengyucui/MakerShelf/releases)

原生 **SwiftUI macOS** 客户端，用来把 MakerWorld 中文站和国际站的模型、介绍与图片归档到本机，也可以把自己的模型文件整理成本地藏品。主导航只有「模型库、下载任务、设置」。

当前版本已接入站点登录页、公开模型解析和真实归档写入。作者公开作品可在未登录时预览；当前账号的收藏 / 作品列表和 3MF 下载依赖你在应用内完成官方登录。站点没有公开官方 API，实现按 MakerWorld 当前网页接口适配，可能随站点改动而失效。

![MakerShelf 工作台](docs/界面预览-工作台.png)

## 获取 MakerShelf

- 最新源码与版本说明：[GitHub Releases](https://github.com/pengyucui/MakerShelf/releases)
- 当前公开版本：`v1.0`
- Release Action 会提供重新构建的未签名 ZIP 和 SHA-256；正式安装包仍需完成 Developer ID 签名与 Apple 公证。你也可以直接从源码运行。

## 打开工程

1. 使用 **Xcode 15 或更新版本**打开根目录的 `MakerShelf.xcodeproj`。
2. 选择共享 Scheme **MakerShelf**，运行目标为 **My Mac**。
3. 最低系统要求为 **macOS 14**，窗口默认 1420 × 950，最小 1080 × 720。

工程不依赖第三方 Swift 包。首次使用请在设置中选择归档目录，再分别连接中文站 / 国际站。

## 已实现功能

| 功能 | 当前行为 |
| --- | --- |
| 模型库 | Native Glass 主窗口、统一尺寸网格 / 列表、中文站 / 国际站 / 本地模型、作者、分类与下载状态筛选，支持搜索、排序和分页加载 |
| 模型详情 | 选中卡片后在右侧 Inspector 查看多图、介绍、文件、归档信息和来源链接，并可直接下载或在访达中打开 |
| 统一导入 | 模型链接；当前账号的收藏 / 发布内容；按用户名、数字 ID 或主页链接获取指定作者的公开发布模型；新建本地模型，三类入口共用一个导入窗口 |
| 本地模型 | Native Glass 双栏创建与编辑页；支持修改资料、封面、展示图片和模型文件，并可拖放或选择 3MF、STL、OBJ、STEP、STP、GCODE、AMF |
| 来源校验 | 精确域名匹配、模型编号检查、用户主页与站点一致性校验 |
| 站点登录 | 打开 MakerWorld 自己的登录页，会话写入本应用数据保护钥匙串；安装后只需授权一次，之后进入设置使用内存中的登录状态 |
| 下载任务 | 真实下载打印配置 3MF（及可用的原始文件）、介绍 HTML、展示图片；暂停 / 继续 / 取消 / 重试、同来源去重、并发上限 |
| 本地归档 | 在线模型使用 `站点/作者_ID/模型名_ID/`；自有模型使用 `本地模型/模型名_ID/`，都包含 `models`、`images`、`description.html`、`metadata.json` |
| 目录选择 | 原生目录选择器、沙盒访问书签、失效提示 |
| 偏好 | 目录授权、首选格式、并发数自动保存 |

首次启动仍会显示 8 个示例模型，方便空库时浏览界面。导入成功的真实模型会写入 `~/Library/Application Support/MakerShelf/library.json`，重启后保留。

## 使用顺序

1. 设置 → 存储与下载 → 选择归档目录。
2. 设置 → 站点账号 → 打开对应站点登录页并完成登录。
3. 导入模型：粘贴模型链接；读取当前账号收藏 / 发布列表；或输入作者用户名、`@用户名`、数字 ID、主页链接读取其公开发布模型。主页链接会自动识别中文站或国际站。
4. 确认清单后加入下载队列；完成后可在模型库和访达中查看。

添加自有模型时，在导入窗口切换到「本地模型」，可把模型文件拖入虚线区域，也可点按该区域打开系统文件选择器。左侧填写资料并管理展示图片，右侧实时预览进入模型库后的卡片和保存位置。应用会复制原始文件，不会移动或修改来源文件；第一张展示图片作为封面，也可手动调整。创建完成后可在模型库的「本地模型」来源中查看。

已归档到本地的模型（自己创建的本地模型，以及已下载的站点模型）都可以编辑。选中卡片后，右侧 Inspector 底部固定显示「编辑本地模型」；卡片上的「编辑」、右键菜单也是同一入口。编辑页会回填现有资料、模型文件和图片，支持追加、移除、调整封面与修改介绍。保存时先建立完整临时归档，写入成功后再替换原归档；模型 ID、归档路径、来源站点和排序位置保持不变。

公开模型链接和指定作者的公开作品可以先预览清单；写入 3MF 等模型文件仍需要对应站点的已登录会话。

## 快捷键

- `⌘N`：导入模型。
- `⌘K`：进入模型库并聚焦搜索。
- `⌘,`：打开设置。

## 项目目录

```text
MakerShelf.xcodeproj/           原生 Xcode 工程与共享 Scheme
MakerShelf/
  App/                         应用入口与页面路由
  Domain/                      模型、查询与导入意图
  Services/                    站点客户端、目录查询、缩略图管线
  Stores/                      页面状态、下载队列、偏好、登录会话
  Views/                       三个主页面、导入窗口、登录页、模型 Inspector
  Resources/                   PNG 示例插画、应用图标、演示 JSON
  MakerShelf.entitlements      目录选择、沙盒书签、网络客户端
prototype/                     前期网页设计稿，保留作视觉对照
index.html                     网页设计稿入口
docs/SwiftUI架构与性能.md        原生实现、并发边界与性能说明
docs/功能梳理.md                功能去重记录
docs/界面设计说明.md            视觉和产品信息架构
docs/Figma重新设计-功能与页面说明.md  发给 Figma 重新设计用的功能、页面与状态说明
```

## 已知边界

- MakerWorld 没有官方开发者 API。登录后的收藏、作品分页和文件下载地址以站点当前行为为准。
- 部分模型可能有付费、积分兑换、地区或风控限制；应用不会绕过这些限制。
- 客户端优先使用 MakerWorld 网页同源接口；遇到网页防护或不可用时，再回退到对应的 `api.bambulab.com` / `api.bambulab.cn` 接口。
- 下载队列不跨进程恢复；已归档文件和模型库索引会保留。
- 当前没有断点续传校验值；继续任务时跳过已经存在的本地文件。
- MakerWorld 不公开其他用户的收藏列表，因此“收藏的模型”只用于当前登录账号；指定作者只读取其公开发布模型。
- 本地模型使用文件快照归档；来源文件以后发生变化时不会自动同步，可进入编辑页重新选择文件并保存。

## 开源与贡献

MakerShelf 是独立社区项目，与 Bambu Lab 或 MakerWorld 没有关联，也未得到其官方认可。使用者应遵守 MakerWorld 条款、模型作者许可及所在地法律；项目不会绕过付费、积分、地区、版权或访问控制。

项目采用 [Apache License 2.0](LICENSE)，归属信息见 [NOTICE](NOTICE)。欢迎先阅读[贡献指南](CONTRIBUTING.md)、[行为准则](CODE_OF_CONDUCT.md)、[安全策略](SECURITY.md)与[发布流程](docs/发布流程.md)，再提交 Issue 或 Pull Request。版本变化记录在 [CHANGELOG.md](CHANGELOG.md)。

## 网页设计参考

网页仅用于对照设计。需要查看历史设计时，可在项目目录运行：

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

本轮重新设计的 macOS Native Glass 确认稿：

- [可交互本地确认稿](http://127.0.0.1:8765/prototype/native-glass.html)：包含毛玻璃侧栏、原生工具栏、模型网格、右侧 Inspector、深色模式和本地模型 Sheet。
- [Figma 基础规范与窗口骨架](https://www.figma.com/design/pVFk7WDb4x9SrsTGTPlNe2)：包含 Light/Dark 颜色变量、SF Pro 字体、材质层级与 Apple macOS Title Bar。

历史版本仍可打开 [方案 A 网页设计稿](http://127.0.0.1:8765/prototype/?variant=A)。
