# iOS 风格笔记编辑器设计规格

**日期**: 2026-05-28  
**范围**: 重设计记录创建和显示页面，参考 iOS 备忘录应用  
**目标**: 提供全屏、无干扰、图文混排的编辑体验

---

## 1. 概述

SmileJar 当前的记录编辑器采用表单风格（标题框 + 正文框 + 工具）。新设计参考 iOS 备忘录，改为全屏沉浸式编辑，支持文本、图片、语音、标签的无缝混排，完全在编辑页面内完成所有操作，无额外弹窗干扰。

### 核心目标
- 简约原生风格，适配 iOS 设计标准
- 完全参照备忘录交互逻辑
- 支持图文混排（图片单独占一行，穿插文本段落）
- 自动保存草稿，手动保存时点击"完成"
- 保留分组选择功能（储蓄罐）

---

## 2. 文件结构

### 新增文件

```
SmileJar/Features/iOSNoteEditor/
├── iOSNoteEditorView.swift          # 主编辑界面
├── iOSNoteEditorModel.swift         # 状态管理（@Observable）
└── iOSNoteEditorComponents.swift    # 复用组件
```

### 修改文件

无：保留现有 `EntryEditorView`，新设计并行开发和测试。

### 复用的现有组件

- 数据模型：`Entry`、`Group`、`MediaAttachment`、`Tag`
- 存储：`MediaStore`（图片保存/加载）
- 标题服务：`LocalTitleService`、`ClaudeAIService`
- 颜色系统：`AppColors`

---

## 3. UI 布局

### 3.1 整体结构

```
┌────────────────────────────────────────┐
│ 返回  日期(M月d日, 如"5月28日")  完成  │  ← NavigationBar (height: 56pt)
├────────────────────────────────────────┤
│ [🎯微笑] [😊温暖] [💪成长] ...        │  ← GroupSelector (H-scroll, padding: 16)
├────────────────────────────────────────┤
│                                        │
│ ┌──────────────────────────────────┐  │
│ │ 标题作为第一行（可手动编辑）      │  │
│ │                                  │  │
│ │ 正文内容可以很长...              │  │
│ │                                  │  │
│ │ 图片 1                            │  │
│ │ ┌──────────────────────────────┐ │  │
│ │ │                              │ │  │  ← MainEditor
│ │ │         图片预览             │ │  │     (TextEditor + 图片层)
│ │ │                              │ │ [x]  可点击删除
│ │ └──────────────────────────────┘ │  │
│ │                                  │  │
│ │ 更多文字...                      │  │
│ │                                  │  │
│ └──────────────────────────────────┘  │
│                                        │
├────────────────────────────────────────┤
│ [📷照片] [🎤语音] [#标签]              │  ← ToolBar (padding: 16, spacing: 18)
└────────────────────────────────────────┘
```

### 3.2 组件详细设计

#### NavigationBar
- **样式**: `.navigationBarTitleDisplayMode(.inline)` + 自定义日期
- **左按钮**: "返回" 按钮（系统默认）
- **右按钮**: "完成" 按钮
  - 当 `isSaving == true` 时显示 loading indicator
  - 当内容为空时可选禁用（或始终可用，取决于业务需求）
- **中间**: 日期标签（如"5月28日"），字体 `.system(size: 16, weight: .regular)`

#### GroupSelector
- **宽度**: 全宽，左右 padding 16
- **高度**: 自适应（约 44-60pt）
- **滚动方向**: 水平，`.showsIndicators(false)`
- **样式**: 保持现有 pill 风格
  - 未选中：透明背景 + 彩色文字
  - 已选中：彩色填充 + 白色文字
- **功能**: 点击切换当前储蓄罐
- **分隔符**: 内置分组与自定义分组之间显示竖线（可选）

#### MainEditor
- **组件**: TextEditor（支持多行、自动换行）
- **背景**: `.scrollContentBackground(.hidden)` + 透明（融入页面背景）
- **内边距**: 16pt
- **最小高度**: 200pt
- **Placeholder**: "此刻发生了什么……"（灰色，当内容为空时显示）
- **字体**: 
  - 标题行（第一行）：`.system(size: 17, weight: .semibold)`
  - 正文：`.system(size: 16, weight: .regular)`
- **图片渲染**:
  - 图片用 ZStack 层叠在 TextEditor 下方（视觉上"内联"）
  - 每张图片占一行，宽度 = 编辑区宽度 - padding
  - 图片右上角显示删除按钮 (×)
  - 图片间距：8pt

#### ToolBar
- **位置**: 底部，SafeArea 上方
- **样式**: 水平排列，左对齐，右侧 Spacer
- **按钮**（从左到右）:
  - 📷 照片：PhotosPicker（多选，最多 9 张）
  - 🎤 语音：VoiceRecorder Sheet
  - # 标签：TagPicker Sheet
- **字体**: `.system(size: 13, weight: .regular)`
- **颜色**: `AppColors.warmOrange`
- **间距**: 按钮间 18pt

---

## 4. 数据模型与状态管理

### 4.1 iOSNoteEditorModel

```swift
@Observable
final class iOSNoteEditorModel {
    // 编辑内容（融合标题 + 正文）
    var editorText: String = ""
    
    // 分组和标签
    var selectedGroupID: PersistentIdentifier?
    var selectedTags: Set<PersistentIdentifier> = []
    
    // 附件管理
    var attachments: [DraftAttachment] = []  // 同 EntryEditorModel
    
    // 时间戳
    var createdAt: Date = .now
    var updatedAt: Date = .now
    
    // 编辑状态
    var isDirty: Bool = false
    var isSaving: Bool = false
    var lastAutoSaveTime: Date = .now
    
    // 方法
    func scheduleAutoSave() { ... }
    func performAutoSave() async { ... }
    func extractTitleAndBody() -> (String, String) { ... }
    func load(from entry: Entry) { ... }
}
```

### 4.2 标题提取规则

编辑器内容格式：
```
标题行（用户手动编辑或自动生成）
正文段落...
<image id="uuid1">
更多正文...
```

保存时：
1. 第一行作为标题，若为空则由服务自动生成
2. 其余内容（去除 `<image>` 标记）为正文
3. `<image>` 标记用于序列化和查找 attachments

---

## 5. 交互流程

### 5.1 编辑 → 自动保存

```
用户编辑文本或插入图片
    ↓
isDirty = true，启动 debounce timer（3秒）
    ↓
3秒内有新编辑 → 重置 timer
3秒内无编辑 → performAutoSave()
    ↓
保存当前内容为草稿到 SwiftData
    ↓
isSaving 期间 UI 给予反馈（可选：导航栏加 loading）
```

### 5.2 点击"完成"

```
用户点击右上角"完成"
    ↓
执行最终保存（同步入库 Entry）
    ↓
提取标题（第一行）和正文（去除图片标记）
    ↓
若标题为空 → 调用 LocalTitleService 快速生成
    ↓
保存成功 → 关闭编辑页面
    ↓
后台触发 AI 标题生成（若启用，不阻塞 dismiss）
```

### 5.3 返回键行为

```
用户点击返回按钮
    ↓
isDirty == true?
    ├─ YES → 弹提示："有未保存的修改，确定放弃吗？"
    │         用户选择：放弃 / 保存
    └─ NO  → 直接返回（无提示）
```

### 5.4 照片插入和删除

```
用户点击"照片"按钮
    ↓
唤起 PhotosPicker（多选，最多 9 张）
    ↓
用户选择多张 → 一次性加载
    ↓
生成缩略图 → 保存到 MediaStore
    ↓
为每张图片生成 <image id="uuid"> 标记
    ↓
插入到光标位置（保持顺序）
    ↓
图片在编辑区下方预览，右上角可点击删除
    ↓
点击删除 → 移除标记和附件，UI 刷新
```

---

## 6. 视觉风格与适配

### 6.1 配色和字体

- **文本颜色**：`AppColors.textPrimary`（默认）、`AppColors.textSecondary`（辅助）
- **背景**：`AppColors.backgroundGradient`（保留现有梯度）或调整为 `.background(.fill)` 后续决定
- **分组 pill**：
  - 未选中：`Color(hex: groupColorHex).opacity(0.15)` 背景 + 彩色文字
  - 已选中：`Color(hex: groupColorHex)` 填充 + 白色文字
- **工具栏按钮**：`AppColors.warmOrange`

### 6.2 Dark Mode 适配

- 所有颜色通过 `AppColors` 自动适配
- 文本编辑区背景：保持透明，继承 AppColors.backgroundGradient
- 无需额外配置，利用现有颜色系统

### 6.3 字号和间距

- **导航栏日期**：16pt, regular
- **标题行**：17pt, semibold
- **正文**：16pt, regular
- **工具栏按钮**：13pt, regular
- **水平间距**：16pt（页面 padding），8pt（组件间距）
- **竖直间距**：16pt（主要分区），8pt（细节）

---

## 7. 错误处理与边界情况

### 7.1 网络/AI 服务故障

- 自动保存失败 → 本地重试（debounce），不弹窗
- AI 标题生成失败 → 回退到 LocalTitleService 生成的标题，无感知

### 7.2 图片加载失败

- 照片保存失败 → 移除该图片，提示用户（Toast）
- 缩略图生成失败 → 显示默认占位图，不影响编辑

### 7.3 内容验证

- 保存时：至少有标题、正文或附件中的一项非空
- 分组必选：若未选择分组，完成按钮禁用或提示选择

---

## 8. 实现细节

### 8.1 图文混排的技术方案

**方案**：TextEditor + ZStack 图片层

**原理**：
- TextEditor 只显示纯文本和 `<image>` 标记（隐藏显示）
- 单独用 VStack 渲染图片，放在 TextEditor 下方
- 通过计算光标位置，模拟"内联"效果

**优点**：
- 文本编辑和图片管理清晰分离
- 易于图片删除和排序
- 不需要 UITextViewRepresentable（复杂度低）

**缺点**：
- 文字不能真正围绕图片流动
- 需要维护标记的一致性

### 8.2 自动保存的 debounce 机制

```swift
private var autoSaveTask: Task<Void, Never>?

func scheduleAutoSave() {
    autoSaveTask?.cancel()
    autoSaveTask = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3秒
        await performAutoSave()
    }
}
```

### 8.3 与现有 Entry 的兼容性

新编辑器保存时：
- `Entry.title` ← 提取的标题行
- `Entry.bodyText` ← 正文（去除图片标记）
- `Entry.attachments` ← 管理的附件列表
- 不破坏现有数据结构

编辑现有 Entry 时：
- 从 SwiftData 加载 Entry
- 合并 `title + "\n" + bodyText` 为 `editorText`
- 加载附件到 `attachments` 数组

---

## 9. 测试清单

### 单元测试
- [ ] 标题和正文的提取逻辑
- [ ] 自动保存的 debounce 行为
- [ ] 图片标记的序列化和反序列化

### 集成测试
- [ ] 创建新记录：编辑 → 保存 → 验证 Entry 数据
- [ ] 编辑现有记录：加载 → 修改 → 保存 → 验证更新
- [ ] 图片插入和删除：插入多张 → 删除一张 → 验证附件列表
- [ ] 自动保存：编辑后等待 → 验证草稿存在
- [ ] 返回确认：修改后点返回 → 验证提示

### 功能测试（手动）
- [ ] 分组切换（图片、颜色正确）
- [ ] 标签选择和显示
- [ ] 语音录入和转录
- [ ] Dark Mode 适配
- [ ] iPad 横屏适配（可选后续）

---

## 10. 后续优化方向

1. **图片拖拽排序**：支持长按拖拽调整图片顺序
2. **图片编辑**：点击图片可裁剪、旋转、调整亮度
3. **Markdown 支持**：若需要更丰富的格式
4. **离线编辑**：完全离线时也能自动保存
5. **iPad 横屏**：优化导航栏和工具栏布局

---

## 结论

本设计为 SmileJar 提供了一个符合 iOS 原生标准、简洁高效的笔记编辑器。通过自动保存、图文混排、一页完成所有操作，大幅提升用户体验。实现复用现有的数据和服务层，降低集成风险。
