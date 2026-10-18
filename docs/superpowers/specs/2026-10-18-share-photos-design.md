# 从相册分享照片新建记录 设计文档

**日期**：2026-10-18
**背景**：用户希望在系统「照片」App 中选中 1~N 张照片 → 分享 → 微笑储蓄罐，App 自动新建一条记录并进入编辑状态。
系统照片 App 的分享面板只列出带 Share Extension 的 App，现有 `CFBundleDocumentTypes`（打开方式）不适用，因此需要新增 Share Extension。

---

## 决策摘要

| 项 | 决定 |
|----|------|
| 交接方式 | 扩展写入 App Group 收件箱 → 通过 `smilejar://share` 唤起主 App（responder chain 调 `openURL:`，非官方 API） |
| 兜底 | 主 App 每次 `scenePhase == .active` 检查收件箱；扩展若跳转失败提示用户手动打开 |
| 媒体类型 | 仅照片（与编辑器能力一致），最多 9 张（与 App 内选择器一致） |
| 格式 | 主 App 解码后走现有 `insertPhotos`，统一存为 JPEG |
| 默认分组 | 第一个内置罐（编辑器现有逻辑），进入编辑后可切换 |
| 编辑器已打开 | 编辑器内弹窗：[插入当前记录] / [新建记录] / [取消] |

---

## 改动范围

| 文件 | 类型 | 说明 |
|------|------|------|
| `project.yml` | 修改 | 新增 `SmileShare` app-extension target；主 App 嵌入扩展；两者 entitlements 指向 App Group；主 App 注册 URL scheme |
| `Smile/Info.plist` | 修改 | `CFBundleURLTypes` 注册 `smilejar` |
| `Smile/Smile.entitlements` | 修改 | `com.apple.security.application-groups = [group.com.chuzhanfeng.smile]` |
| `SmileShare/Info.plist` | 新增 | `NSExtension` 配置 |
| `SmileShare/SmileShare.entitlements` | 新增 | 同一 App Group |
| `SmileShare/ShareViewController.swift` | 新增 | 扩展主逻辑 |
| `Smile/Core/SharedInbox/SharedInbox.swift` | 新增 | 收件箱读写，两个 target 共同编译 |
| `Smile/Core/SharedInbox/ShareInboxCenter.swift` | 新增 | 主 App 内的协调状态（`@Observable`） |
| `Smile/SmileApp.swift` | 修改 | 创建 `ShareInboxCenter` 注入 environment |
| `Smile/App/RootView.swift` | 修改 | `onOpenURL` 分流 `smilejar://share`；前台检查；无编辑器时打开带图编辑器 |
| `Smile/Features/EntryEditor/iOSNoteEditorView.swift` | 修改 | `initialImages` 参数；登记打开状态；收图弹窗；冷启动补选分组 |
| `SmileTests/SharedInboxTests.swift` | 新增 | 收件箱单测 |
| `SmileTests/ShareInboxCenterTests.swift` | 新增 | 协调逻辑单测 |

---

## 1. Share Extension `SmileShare`

- Bundle ID：`com.chuzhanfeng.smile.share`，部署目标 iOS 17.0，版本号与主 App 一致。
- `NSExtensionPointIdentifier = com.apple.share-services`
- `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`（纯代码，无 storyboard）
- `NSExtensionActivationRule`：`NSExtensionActivationSupportsImageWithMaxCount = 9`（系统据此在超过 9 张或含视频时不显示本 App）。
- 显示名：微笑储蓄罐。

### ShareViewController 流程

1. 显示一个居中小卡片：「正在发送到微笑储蓄罐…」。
2. 遍历 `extensionContext.inputItems` 中所有 `NSItemProvider`，筛出 `hasItemConformingToTypeIdentifier(UTType.image)`。
3. 对每个 provider：
   - 优先 `loadFileRepresentation(forTypeIdentifier: UTType.image.identifier)`，在回调内把临时文件**复制**到 batch 临时目录（回调返回后临时文件即失效）。不解码图片，规避扩展 ~120MB 内存上限。
   - 失败则退回 `loadDataRepresentation`；再失败则 `loadObject(ofClass: UIImage.self)` 并 `jpegData(0.9)`。
   - 文件按原顺序命名 `0001.<ext>`、`0002.<ext>`…，保证顺序与用户选择一致。
4. 全部完成后 `SharedInbox.commit(batch)`。若一张都没拿到 → 卡片提示「没有可用的照片」，1.5 秒后 `cancelRequest`。
5. 调用 `openMainApp(URL("smilejar://share"))`：沿 responder chain 找到响应 `openURL:` 的对象（`UIApplication`）并调用 `open(_:options:completionHandler:)`。
   - 成功 → `completeRequest`。
   - 找不到 / 返回 false → 卡片改为「已收到 N 张照片，请打开微笑储蓄罐继续编辑」+ [好的] 按钮，点击后 `completeRequest`。

---

## 2. SharedInbox（两个 target 共用）

```swift
struct SharedInbox {
    static let appGroupID = "group.com.chuzhanfeng.smile"
    let rootURL: URL                       // 生产：<AppGroup>/ShareInbox
    static func production() -> SharedInbox?   // 容器不可用时返回 nil

    struct Batch: Identifiable { let id: UUID; let url: URL; let createdAt: Date }

    func beginBatch() throws -> PendingBatch   // 创建 .tmp-<uuid>/
    func commit(_ pending: PendingBatch) throws  // 原子重命名为 <uuid>/
    func pendingBatches() -> [Batch]           // 仅已提交的，按 createdAt 升序
    func fileURLs(in batch: Batch) -> [URL]    // 按文件名排序
    func remove(_ batch: Batch)
    func purgeStaleTemporaries(olderThan: TimeInterval = 3600)  // 清理扩展崩溃遗留的 .tmp-*
}

struct PendingBatch { let id: UUID; let url: URL
    func addFile(from src: URL, index: Int) throws
    func addData(_ data: Data, ext: String, index: Int) throws }
```

- `pendingBatches()` 忽略以 `.tmp-` 开头的目录，保证主 App 永远读不到半成品。
- `createdAt` 取目录的 creationDate。
- `rootURL` 可注入，便于单测使用临时目录。

---

## 3. ShareInboxCenter（主 App）

`@Observable @MainActor final class ShareInboxCenter`，在 `SmileApp` 中创建并 `.environment()` 注入。

```swift
private(set) var openEditorCount = 0
var incomingImages: [UIImage]?        // 已解码、待交给编辑器的一批
var newEntryRequested = false         // 编辑器选择「新建记录」后置 true

func editorDidAppear()  { openEditorCount += 1 }
func editorDidDisappear() { openEditorCount = max(0, openEditorCount - 1) }

/// 若当前没有待处理的 incomingImages，则取最早的 batch 解码，
/// 填入 incomingImages 并删除该 batch。返回是否取到。
@discardableResult func pullNextBatch() -> Bool

/// RootView 打开新编辑器时调用：取走图片并清空状态
func takeImagesForNewEntry() -> [UIImage]
```

- `inbox` 依赖注入（`SharedInbox?`），测试用临时目录。
- 解码：`UIImage(contentsOfFile:)` 逐个读取；失败的文件跳过并计数 `lastDecodeFailures`，供 UI 提示。

---

## 4. RootView 变更

- `.onOpenURL`：`url.scheme == "smilejar" && url.host == "share"` → `checkShareInbox()`；其余保持原 zip 逻辑。
- `.onChange(of: scenePhase)` 到 `.active` → `checkShareInbox()`（同时调用 `purgeStaleTemporaries`）。
- `checkShareInbox()`：`center.pullNextBatch()`；之后若 `center.openEditorCount == 0` 则 `openShareEditor()`。若 >0，由已打开的编辑器自己弹窗（见第 5 节）。
- `openShareEditor()`：`shareImages = center.takeImagesForNewEntry()`；`showEntryEditor = true`。现有 + 号 sheet 改为把 `shareImages` 作为 `initialImages` 传入，`onDismiss` 时清空 `shareImages`。
- `.onChange(of: center.openEditorCount)`：降到 0 时——
  - 若 `center.newEntryRequested && center.incomingImages != nil` → 置回 false，`openShareEditor()`；
  - 否则若收件箱还有 batch → `checkShareInbox()`（连续分享多次的情况逐批处理）。
- 编辑器 sheet 已在关闭动画中时直接设 `showEntryEditor = true` 可能失效：`openShareEditor()` 在计数归零的回调里延迟到下一个 runloop（`Task { @MainActor in ... }`）执行。

---

## 5. iOSNoteEditorView 变更

- 新增参数 `initialImages: [UIImage] = []`。`onAppear` 中 `initialize()` 之后，若非空则 `await insertPhotos(initialImages)`（新建记录时 `focusedSegmentID == nil`，照片追加在首个文本段之后，首行仍留给标题）。随后照常延迟聚焦首行。
- `onAppear` 调 `center.editorDidAppear()`，`onDisappear` 调 `center.editorDidDisappear()`。
- 收图弹窗：`.alert("收到 \(n) 张照片", isPresented: center.incomingImages != nil && 本编辑器是最上层)`。
  - 「最上层」判断：三处调用点（RootView 的 +、GroupDetailView 新增、EntryDetailView 编辑）同一时刻最多只有一个编辑器存在，计数 > 0 时即视为当前编辑器为目标，无需额外判断。
  - **插入当前记录**：`insertPhotos(center.incomingImages!)`（锚点为当前焦点段，没有则末尾），清空 `incomingImages`。
  - **新建记录**：`center.newEntryRequested = true`；若 `canSave` 则 `await save()`（内部会 dismiss），否则直接 `dismiss()`。由 RootView 在计数归零后打开新编辑器。
  - **取消**：清空 `incomingImages`。
- 冷启动补选分组：`.onChange(of: allGroups.count)`，若 `model.selectedGroupID == nil` 则 `model.selectDefaultGroup(...)`。
- 带图打开时 `initialImages` 解码失败计数 > 0 → 复用现有「照片插入失败」弹窗。

---

## 6. 错误与边界

| 场景 | 处理 |
|------|------|
| App Group 容器不可用（签名配置错误） | 扩展提示「无法保存照片」并 cancel；主 App `production()` 为 nil 时跳过检查 |
| 部分照片加载/解码失败 | 跳过，其余照常；主 App 弹「照片插入失败」 |
| 连续多次分享未打开 App | 逐批处理，每批一条记录 |
| 扩展崩溃留下 `.tmp-*` | 主 App 前台时清理超过 1 小时的临时目录 |
| openURL 被系统封禁 | 扩展提示手动打开；前台检查兜底 |
| 编辑器内正打开相册/相机/语音等子页面 | 已知限制：弹窗待子页面关闭后显示 |
| 「新建记录」时当前编辑器无内容 | 直接关闭，不保存 |

---

## 7. 测试

**单元测试**
- `SharedInboxTests`：begin+commit 后可列出；未 commit 的不可列出；多 batch 按时间升序；`fileURLs` 按序号排序；remove 后不再列出；`purgeStaleTemporaries` 仅删过期临时目录。
- `ShareInboxCenterTests`：`pullNextBatch` 解码并删除 batch、跳过坏文件并计数；已有 `incomingImages` 时不重复拉取；`takeImagesForNewEntry` 清空状态；`editorDidAppear/Disappear` 计数且不为负。

**真机手动测试**
1. 照片 App 分享 1 张 → 自动跳回并进入新编辑器，照片在标题行下方。
2. 分享 9 张 → 顺序与选择一致；选第 10 张时分享面板不出现本 App。
3. App 未运行（冷启动）分享 → 分组正确默认选中。
4. 编辑器已打开时分享 → 三个选项分别符合预期；「新建记录」后原记录已保存。
5. 分享后不跳转（模拟：直接手动切回）→ 前台检查打开编辑器。
6. HEIC、截图、从「文件」App 分享图片均可。
