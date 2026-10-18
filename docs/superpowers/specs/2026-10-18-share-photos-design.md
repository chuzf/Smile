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
| 格式 | 与 App 内相册选择器一致：全分辨率、EXIF 方向摆正，存为 JPEG（质量 0.9）；编辑器逐张解码，不降采样 |
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
| `Smile/Features/EntryEditor/iOSNoteEditorView.swift` | 修改 | 登记打开状态；空白编辑器 onAppear 直接取用分享照片；收图弹窗；逐张插入分享的原图文件；冷启动补选分组 |
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
    func commit(_ pending: PendingBatch) throws -> Batch  // 原子重命名为 <uuid>/
    func discard(_ pending: PendingBatch)      // 扩展出错时丢弃临时目录
    func pendingBatches() -> [Batch]           // 仅已提交的，按 createdAt 升序
    func fileURLs(in batch: Batch) -> [URL]    // 按文件名排序
    func remove(_ batch: Batch)
    func purgeStaleTemporaries(olderThan: TimeInterval = 3600, now: Date = .now)  // 清理扩展崩溃遗留的 .tmp-*
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

> **最终实现**：下面是实际 API（早期草稿中的 `incomingImages: [UIImage]`、`lastDecodeFailures`、同步 `pullNextBatch() -> Bool` 已被替换）。

```swift
private(set) var openEditorCount = 0
private(set) var incomingPhotoURLs: [URL]?  // 已校验、待交给编辑器的一批照片文件（按分享顺序）
private(set) var incomingFailures = 0       // 本批无法读取的文件数，只在 incomingPhotoURLs != nil 时有意义
private(set) var hasUnreportedReadFailure = false

init(inbox: SharedInbox? = SharedInbox.production(), processingRoot: URL = tmp/ShareProcessing)

func editorDidAppear()
func editorDidDisappear()

enum PullResult { case nothing, ready(count: Int), allFailed(failures: Int) }
/// 没有待处理照片且不在拉取中时，认领最早的、本进程未处理过的 batch 并在后台校验
@discardableResult func pullNextBatch() async -> PullResult

/// 取走照片文件与失败计数并清空状态；调用方从此拥有这些文件，用完必须删除
func takeIncoming() -> (urls: [URL], failures: Int)
/// 放弃当前这批：删除文件及认领目录
func discardIncoming()
/// 删除已交接的文件，认领目录空了一并删除
nonisolated static func deleteHandedOffFile(_ url: URL)

func deferReadFailureNotice()
func clearReadFailure()
/// 清理扩展遗留的 `.tmp-*`，以及超过 1 小时未改动的 `tmp/ShareProcessing/*`（当前持有的那批除外）
func purgeStaleTemporaries(olderThan: TimeInterval = 3600, now: Date = .now)
```

- `inbox` 依赖注入（`SharedInbox?`），测试用临时目录；`processingRoot` 同样可注入。
- 认领：处理前先把 batch 从收件箱移到 `tmp/ShareProcessing/<batchID>/`（并刷新目录修改时间），这样后续全分辨率解码若导致进程被杀，batch 不会变成每次启动都触发崩溃的「毒 batch」。认领目录不在拉取后删除，归交接出去的这批照片所有。
- 校验（后台、不解码像素）：`CGImageSourceCreateWithURL` 成功、`CGImageSourceGetCount > 0`、首帧属性的像素宽高为正。有效文件按原顺序保留；无效文件当场删除并计入 `incomingFailures`。全部无效时删除认领目录，返回 `.allFailed`，不设置 `incomingPhotoURLs`。
- 中心只持有文件 URL，不持有解码后的图片；全分辨率解码由编辑器逐张完成（见第 5 节），避免 9 张 48MP 原图同时解码（每张约 190MB）。

---

## 4. RootView 变更

- `.onOpenURL`：`url.scheme == "smilejar" && url.host == "share"` → `checkShareInbox()`；其余保持原 zip 逻辑。
- `.onChange(of: scenePhase)` 到 `.active` → `checkShareInbox()`（同时调用 `purgeStaleTemporaries`）。
- `checkShareInbox()`：
  - 若 + 号编辑器正在弹出但尚未 `onAppear`（`showEntryEditor && openEditorCount == 0`）→ 直接返回，等计数变化时再处理（避免 `onOpenURL` 与前台检查双触发时覆盖第一批）。
  - `center.pullNextBatch()`；若 `openEditorCount > 0` 则到此为止，由已打开的编辑器弹窗（见第 5 节）。
  - 否则取到照片 → `openShareEditor()`；整批读取失败 → 弹「照片读取失败」。
- `openShareEditor()`：~~`center.takeIncoming()` 写入 `shareImages` / `shareFailures`，作为 `initialImages` 传入~~。
  **最终实现**：照片不经 RootView 中转，留在 `ShareInboxCenter`；`openShareEditor()` 只设 `showEntryEditor = true`（带 1 秒看门狗，按呈现世代复位），新编辑器 onAppear 时发现自己是空白编辑器就直接取用插入。
- `.onChange(of: center.openEditorCount)` 降到 0 时，等待 350ms（让上一个 sheet 的关闭动画结束），然后：
  - 若 `center.incomingPhotoURLs != nil`（用户在编辑器里选了「新建记录」）→ `openShareEditor()`；
  - 否则 `checkShareInbox()`（连续分享多次时逐批处理）。

---

## 5. iOSNoteEditorView 变更

- ~~新增参数 `initialImages: [UIImage] = []`~~。**最终实现**：没有 `initialImages` 参数；`onAppear` 中 `initialize()` 之后检查 `center.incomingPhotoURLs`，若本编辑器是全新、空白、未改动且没有照片正在编码，则直接 `takeIncoming()` 插入（`focusedSegmentID == nil`，照片追加在首个文本段之后，首行仍留给标题），否则弹收图询问。
- 插入分享照片：`insertPhotos` 接受 `PhotoSource`（`.image(UIImage)` 来自相册选择器，`.file(URL)` 来自分享）。`.file` 在后台 `Task.detached { autoreleasepool { … } }` 中逐张 `UIImage(contentsOfFile:)` → `jpegData(compressionQuality: 0.9)` → `ThumbnailGenerator` 缩略图，随后删除源文件；同一时刻只解码一张全分辨率原图，结果与相册选择器（`PHImageManagerMaximumSize` + JPEG 0.9）一致，方向随 EXIF 保留。编辑器中途关闭时删除已写入未插入的照片以及剩余未处理的源文件。
- `onAppear` 调 `center.editorDidAppear()`，`onDisappear` 调 `center.editorDidDisappear()`。
- 收图弹窗：编辑器本地 `@State showShareChoice`，在 `onAppear` 及 `center.incomingPhotoURLs` 由 nil 变为非 nil 时置 true；`.alert("收到 N 张照片", isPresented: $showShareChoice)`。
  - 三处调用点（RootView 的 +、GroupDetailView 新增、EntryDetailView 编辑）同一时刻最多只有一个编辑器存在，无需判断「哪个编辑器是目标」。
  - 当前编辑器是**空白的新记录**（无内容、未修改）时不弹窗，直接插入（两个选项结果相同）。
  - 编辑器上有其他 alert/sheet/相机正在显示时，弹窗排队，待其关闭后约 0.35s 再弹。
  - **插入当前记录**：`center.takeIncoming()` 后 `insertPhotos`（锚点为当前焦点段，没有则末尾）。
  - **新建记录**：保留 `incomingPhotoURLs`；若 `canSave` 则 `await save()`（内部会 dismiss），否则直接 `dismiss()`。由 RootView 在计数归零后打开新编辑器。
  - **取消**：`discardIncoming()`，删除这批文件。
- 冷启动补选分组：`.onChange(of: allGroups.count)`，若 `model.selectedGroupID == nil` 则 `model.selectDefaultGroup(...)`。
- 读取失败（中心校验不通过的 `incomingFailures` + 编辑器解码/编码 `.file` 失败的张数）> 0 → 「照片读取失败」；落盘失败 → 「照片插入失败」（提示存储空间）。

---

## 6. 错误与边界

| 场景 | 处理 |
|------|------|
| App Group 容器不可用（签名配置错误） | 扩展提示「无法保存照片」并 cancel；主 App `production()` 为 nil 时跳过检查 |
| 部分照片无法读取 | 跳过，其余照常；主 App 弹「照片读取失败」 |
| 插入过程中 App 被杀 | batch 已移出收件箱，不会重复触发；`tmp/ShareProcessing` 遗留目录超过 1 小时后清理 |
| 连续多次分享未打开 App | 逐批处理，每批一条记录 |
| 扩展崩溃留下 `.tmp-*` | 主 App 前台时清理超过 1 小时的临时目录 |
| openURL 被系统封禁 | 扩展提示手动打开；前台检查兜底 |
| 编辑器内正打开相册/相机/语音等子页面或其他弹窗 | 弹窗排队，待其关闭后显示 |
| 「新建记录」时保存失败 | 显示保存失败，关闭后重新询问；照片保留在 center |
| 带图打开后「放弃」 | 删除该草稿的媒体目录（自动保存已建出记录时保留） |
| 「新建记录」时当前编辑器无内容 | 直接关闭，不保存 |

---

## 7. 测试

**单元测试**
- `SharedInboxTests`：begin+commit 后可列出；未 commit 的不可列出；多 batch 按时间升序；`fileURLs` 按序号排序；remove 后不再列出；`purgeStaleTemporaries` 仅删过期临时目录。
- `ShareInboxCenterTests`：`pullNextBatch` 校验文件并移出 batch、保留顺序；无效文件被删除并计数；整批无效返回 `.allFailed`；已有 `incomingPhotoURLs` 时不重复拉取；并发拉取只有一个成功；`takeIncoming` 交出仍存在的文件并清空状态；`discardIncoming` 删除文件；`purgeStaleTemporaries` 删除过期认领目录但保留当前持有的；`editorDidAppear/Disappear` 计数且不为负。

**真机手动测试**
1. 照片 App 分享 1 张 → 自动跳回并进入新编辑器，照片在标题行下方。
2. 分享 9 张 → 顺序与选择一致；选第 10 张时分享面板不出现本 App。
3. App 未运行（冷启动）分享 → 分组正确默认选中。
4. 编辑器已打开时分享 → 三个选项分别符合预期；「新建记录」后原记录已保存。
5. 分享后不跳转（模拟：直接手动切回）→ 前台检查打开编辑器。
6. HEIC、截图、从「文件」App 分享图片均可。
