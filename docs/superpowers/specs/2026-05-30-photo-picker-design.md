# 相册选择器 + 拍摄 + 裁剪 设计文档

**日期：** 2026-05-30  
**状态：** 已确认，待实现

---

## 背景

当前编辑器工具栏的"照片"按钮使用系统 `PhotosPicker`，最多选 9 张，直接插入，不支持裁剪，也不支持拍摄。本次新增：

1. 拍摄入口
2. 仿微信风格的自定义相册选择器（网格 + 大图预览）
3. 单张图片裁剪编辑器

---

## 架构概览

```
iOSNoteEditorView（工具栏）
├── 相册按钮 → PhotoLibraryPickerView（Sheet）
│   ├── PhotoGridView（缩略图网格）
│   │   └── 点击格子 → PhotoPreviewView（大图预览）
│   │       └── 点击"编辑" → PhotoCropView（裁剪）
│   └── 底部确定栏（多选直接插入）
└── 拍摄按钮 → CameraPickerView（UIImagePickerController 包装）
    └── 拍完 → PhotoCropView（裁剪）
```

新增文件：
- `Smile/Features/EntryEditor/PhotoLibraryPickerView.swift`
- `Smile/Features/EntryEditor/PhotoPreviewView.swift`
- `Smile/Features/EntryEditor/PhotoCropView.swift`
- `Smile/Features/EntryEditor/CameraPickerView.swift`

修改文件：
- `Smile/Features/EntryEditor/iOSNoteEditorView.swift`（工具栏 + 状态管理）

---

## 各模块详细设计

### 1. 工具栏变化（iOSNoteEditorView）

将原来的单个 `PhotosPicker` 按钮替换为两个按钮，放同一行：

- **相册**（`photo.on.rectangle`图标）→ 弹出 `PhotoLibraryPickerView` sheet
- **拍摄**（`camera`图标）→ 弹出 `CameraPickerView` sheet

新增 State：
```swift
@State private var showPhotoPicker = false
@State private var showCamera = false
```

---

### 2. PhotoLibraryPickerView

使用 `Photos` 框架（`PHAsset` + `PHImageManager`）。

**权限处理：**
- 进入时调用 `PHPhotoLibrary.requestAuthorization(for: .readWrite)`
- 若拒绝，展示提示引导用户去设置

**网格（PhotoGridView）：**
- `LazyVGrid` 3 列，每列等宽
- 每个格子：缩略图（`PHImageManager` 异步加载）+ 右上角圆形勾选框
- 点击格子 = 切换勾选状态（不进入预览）
- 长按格子 或 点击缩略图中心 = 进入大图预览（通过 `fullScreenCover` 展示 `PhotoPreviewView`）
  - 实际交互：**点击格子 = 进入大图预览**，**点击右上角圆圈 = 勾选/取消**
  - 这与微信一致：直接点相片进预览，点圆圈勾选

**底部工具条：**
- 左侧：已选张数提示（"已选 X 张"）
- 右侧："确定"按钮，无选中时灰显不可点
- 点击"确定" → 将已勾选 PHAsset 全部加载为 Data → 依次插入编辑器，不裁剪

**数据流：**
```swift
@State private var selectedAssets: [PHAsset] = []
@State private var previewAsset: PHAsset? = nil   // 触发大图预览
```

---

### 3. PhotoPreviewView

全屏展示单张图片，支持左右翻页浏览（`TabView` 或 `ScrollView paginated`）。

**UI 布局：**
- 顶部导航：左"关闭"，中间序号（"3/12"），右上角圆形勾选框
- 图片区：双指缩放（`MagnificationGesture`）、单指拖动
- 底部工具栏：
  - 左下：**"编辑"** 按钮
  - 右下：**"确定"** 按钮（插入当前图，不裁剪）

**"编辑"按钮可用条件：**
- `selectedAssets.count == 0`（没有勾选其他图）OR `selectedAssets == [currentAsset]`（只勾选了当前这张）
- 若 `selectedAssets.count > 1` 且包含其他图 → "编辑"置灰/隐藏

**点击"编辑"：**
- 加载全分辨率图 → 进入 `PhotoCropView`
- 裁剪完成后：直接关闭 picker，将裁剪后图像插入编辑器

**点击"确定"：**
- 将当前浏览图（不裁剪）插入编辑器，关闭 picker

---

### 4. PhotoCropView

自定义 SwiftUI 裁剪视图。

**布局：**
```
┌────────────────────┐
│  [取消]            │  ← 顶部导航
├────────────────────┤
│                    │
│   ┌──────────┐     │
│   │  裁剪框  │     │  ← 照片铺满，叠加半透明蒙层，裁剪框内清晰
│   └──────────┘     │
│                    │
├────────────────────┤
│       [完成]       │  ← 底部
└────────────────────┘
```

**交互：**
- 双指捏合 → 缩放照片（在裁剪框内）
- 单指拖动照片 → 平移照片
- 拖动裁剪框四个角 → 调整裁剪区域大小（自由比例）
- 拖动裁剪框边中点 → 单轴缩放
- 照片始终不小于裁剪框（防止出现空白区域）

**实现方式：**
- `@State private var cropRect: CGRect` 记录裁剪框位置和大小
- `@State private var imageOffset: CGSize` + `@State private var imageScale: CGFloat` 记录照片变换
- 完成时：使用 `UIGraphicsImageRenderer` 将变换后的图片裁剪为 `UIImage`

**回调：**
```swift
var onCrop: (UIImage) -> Void
var onCancel: () -> Void
```

---

### 5. CameraPickerView

`UIViewControllerRepresentable` 包装 `UIImagePickerController`。

```swift
struct CameraPickerView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void
}
```

- `sourceType = .camera`
- `allowsEditing = false`（不用系统裁剪，拍完后进 PhotoCropView）
- 拍摄完成（`imagePickerController(_:didFinishPickingMediaWithInfo:)`) → 取出 `.originalImage` → 关闭 camera → 弹出 `PhotoCropView`

---

## 数据流：图片如何进入编辑器

所有途径最终都调用同一个 `insertPhoto(_ image: UIImage)` 方法（在 `iOSNoteEditorView` 中）：

```swift
private func insertPhoto(_ image: UIImage) async {
    guard let data = image.heicData() ?? image.jpegData(compressionQuality: 0.85) else { return }
    let filename = "photo-\(UUID().uuidString.prefix(8)).heic"
    guard let relPath = try? mediaStore.save(data: data, entryID: entryDraftID, filename: filename) else { return }
    var draft = DraftAttachment(kind: .photo, relativePath: relPath)
    if let thumbData = ThumbnailGenerator.makePhotoThumbnail(from: data),
       let img = UIImage(data: thumbData) {
        thumbnails[draft.id] = img
    }
    model.insertPhoto(draft, afterSegmentID: anchorID)
}
```

多张（无裁剪）：循环调用此方法。

---

## 错误处理

| 场景 | 处理 |
|------|------|
| 相机权限拒绝 | 提示跳转设置 |
| 相册权限拒绝 | 提示跳转设置 |
| PHAsset 加载失败 | 跳过该图，不 crash |
| 裁剪结果为 nil | 按取消处理，不插入 |

---

## 不在本次范围内

- 视频选择/拍摄
- 裁剪比例锁定（如 1:1、16:9）
- 滤镜、亮度等其他图像调整
- 在详情页重新编辑已插入的照片
