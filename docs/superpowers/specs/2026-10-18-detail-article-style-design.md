# 详情页排版优化 设计文档

**日期**：2026-10-18
**背景**：详情页正文 15pt、行距偏紧、段落之间空一整行、右边参差不齐、文字颜色偏淡，读长文不舒服。希望做成类似公众号的排版。存储结构不变，只改显示。

## 决策摘要

| 项 | 决定 |
|----|------|
| 风格 | 「公众号」（默认）与「书籍」两种，在「App 设置 → 阅读 → 详情排版」切换，带实时预览 |
| 存储 | `@AppStorage("detail_article_style")`，值为 `ArticleStyle.rawValue` |
| 正文渲染 | `UILabel` 包装（`ArticleText`）：两端对齐、固定行高、字距、首行缩进；居中段落居中、不缩进、不两端对齐 |
| 段落切分 | 显示时每个非空行为一段，去掉首尾空白（含全角空格）；缩进由风格参数统一加 |
| 版式 | 标题 22pt 粗体 → 分组名 + 日期（14pt）→ 正文与图片（块间距 24pt）→ 分隔线 + 语音 + 标签 |
| 边距 | 文字与图片共用左右边距，左右边缘对齐 |

## 参数

| 参数 | 公众号 | 书籍 |
|---|---|---|
| 左右边距 | 24pt | 28pt |
| 字号 / 行高 / 字距 | 17 / 30 / 0.3 | 17 / 31 / 0.3 |
| 首行缩进 | 0 | 34pt（两字） |
| 段间距 | 20pt | 10pt |
| 背景 | `#FFFCF7` | 现有米色渐变 |
| 图片圆角 | 4pt | 8pt |
| 正文颜色 | `#3D2B1F` | 同左 |

边距取舍：20pt 一行约 20 字、版面偏满；24pt 约 19 字最平衡；28pt 约 18 字更像杂志，适合书籍风。超过 32pt 在小屏上换行过于频繁。

## 已知限制

两端对齐遇到行首禁排的标点（如前引号「不能在行尾）时，该行字距会被拉开。UILabel 不支持标点悬挂或压缩，字距从 0.5 降到 0.3 以减轻。

## 文件

- 新增 `Smile/Features/EntryDetail/ArticleStyle.swift`：`ArticleStyle`、`Metrics`、`paragraphs(from:)`、`ArticleTextBlock`、`ArticleText`
- 修改 `Smile/Features/EntryDetail/EntryDetailView.swift`：新版式；`DetailPhotoView` 圆角随风格
- 修改 `Smile/Features/Settings/SettingsView.swift`：「阅读」分区与预览
- 新增 `SmileTests/ArticleStyleTests.swift`
