# 文字对齐功能设计

**日期：** 2026-05-30  
**状态：** 已批准

## 概述

在 SmileJar 的笔记编辑器和展示视图中，为文字段落添加居中对齐支持。用户可以逐段切换对齐方式（左对齐 / 居中），编辑时通过段落上方浮动工具栏操作，展示时按保存的对齐值渲染。

## 范围

- **编辑器：** `iOSNoteEditorView` + `iOSNoteEditorModel`
- **展示：** `EntryDetailView`
- **不涉及：** 标题行对齐、图片段落对齐、分享卡片、搜索/导出

## 数据模型

### BodySegment（持久化）

在现有 `BodySegment` 结构体中添加可选的 `alignment` 字段：

```swift
struct BodySegment {
    enum Kind: String, Codable { case text, photo }
    let kind: Kind
    var content: String?
    var path: String?
    var alignment: String?  // nil 或缺失 = 左对齐；"center" = 居中
}
```

向后兼容：旧数据解码时 `alignment` 为 nil，显示为左对齐，无需迁移。

### EditorSegment（内存）

`.text` case 增加 `alignment: TextAlignment` 参数：

```swift
enum EditorSegment: Identifiable {
    case text(id: UUID, content: String, alignment: TextAlignment)
    case photo(DraftAttachment)
}
```

新建段落默认 `.leading`。

## iOSNoteEditorModel 改动

- `updateText(_:for:)` — 保持 alignment 不变
- `updateAlignment(_:for:)` — 新方法，修改指定段落的对齐
- `insertPhoto(_:afterSegmentID:)` — 新建文字段落用 `.leading`
- `buildBodySegments()` — 将 `TextAlignment` 编码为 `"center"` / nil
- `buildEditorSegments(title:bodySegs:allAttachments:)` — 解码 `alignment` 字段
- `collapseAdjacentTextSegments()` — 合并时取第一段的 alignment
- `reset()` — 首段用 `.leading`

## 编辑器 UI

`segmentView` 中 `.text` case 改为 `VStack` 包裹，`focusedSegmentID == id` 时在 `TextEditor` 上方显示浮动工具栏：

- 两个图标按钮：`text.alignleft`（左对齐）、`text.aligncenter`（居中）
- 当前激活状态：橙色背景（`AppColors.warmOrange`），另一个透明背景灰色图标
- 工具栏样式：`.thinMaterial` 背景、`RoundedRectangle(cornerRadius: 8)` 裁剪、轻阴影
- 位置：对齐到段落右侧，`padding(.trailing, 16).padding(.top, 4)`
- `TextEditor` 同步应用 `.multilineTextAlignment(alignment)`

## 展示层

`EntryDetailView.bodyContent` 中文字段落增加：

```swift
.multilineTextAlignment(seg.textAlignment)
.frame(maxWidth: .infinity, alignment: seg.frameAlignment)
```

在 `BodySegment` 加扩展：

```swift
extension BodySegment {
    var textAlignment: TextAlignment {
        alignment == "center" ? .center : .leading
    }
    var frameAlignment: Alignment {
        alignment == "center" ? .center : .leading
    }
}
```

## 文件清单

| 文件 | 改动类型 |
|------|----------|
| `SmileJar/Features/EntryEditor/iOSNoteEditorModel.swift` | 模型扩展 |
| `SmileJar/Features/EntryEditor/iOSNoteEditorView.swift` | 编辑器 UI |
| `SmileJar/Features/EntryDetail/EntryDetailView.swift` | 展示渲染 |
