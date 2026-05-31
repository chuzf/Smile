# "从其他 App 打开"导入设计文档

**日期**：2026-05-31  
**背景**：用户通过微信接收到 `.zip` 备份后，在微信里无法通过系统文件选择器找到该文件。解决方案：将 SmileJar 注册为 `.zip` 文件处理程序，用户可直接从微信"用其他应用打开"→ SmileJar，App 自动触发导入流程。

---

## 改动范围

| 文件 | 类型 | 说明 |
|------|------|------|
| `Smile/Info.plist` | 修改 | 注册 `CFBundleDocumentTypes` 接受 `public.zip-archive` |
| `Smile/App/RootView.swift` | 修改 | 加 `onOpenURL` 监听、确认 Alert、导入逻辑 |

不新增文件，不新增抽象层。

---

## Info.plist 变更

注册 App 为 zip 文件查看器：

```xml
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>SmileJar 备份</string>
        <key>CFBundleTypeRole</key>
        <string>Viewer</string>
        <key>LSItemContentTypes</key>
        <array>
            <string>public.zip-archive</string>
        </array>
    </dict>
</array>
```

注册后，WeChat / 邮件 / AirDrop / Files 等分享的 `.zip` 文件都会在"打开方式"列表中出现 SmileJar。

---

## iOS 文件传递机制

当用户通过"用其他应用打开"把文件发给 SmileJar 时：
- iOS 自动把文件**复制**到 App 沙盒的 `Documents/Inbox/` 目录
- 传入 `onOpenURL` 的 URL 已在 App 沙盒内，**不需要** `startAccessingSecurityScopedResource`
- 导入完成后应删除 Inbox 中的临时文件，避免积累

---

## RootView 变更

新增 4 个 `@State` 变量：

```swift
@State private var inboxImportURL: URL?
@State private var importing = false
@State private var importResult: ImportService.ImportResult?
@State private var importError: String?
```

在 `TabView` 上添加：

1. **`.onOpenURL`**：收到 URL 时，若扩展名为 `zip`，赋值给 `inboxImportURL`
2. **确认 Alert**（`inboxImportURL != nil`）：标题"发现备份文件"，消息"是否立即导入此备份？"，按钮 [取消] / [导入]
3. **成功 Alert**（`importResult != nil`）：与 SettingsView 相同格式的结果摘要
4. **失败 Alert**（`importError != nil`）：显示错误信息

新增私有方法：

```swift
@MainActor
private func doInboxImport(from url: URL) async {
    importing = true
    defer {
        importing = false
        try? FileManager.default.removeItem(at: url)  // 清理 Inbox
    }
    do {
        importResult = try ImportService.importBackup(
            from: url, context: context, mediaStore: .production())
    } catch {
        importError = error.localizedDescription
    }
}
```

---

## 用户流程

1. 微信接收到 `.zip` 备份文件
2. 点文件 → 点分享/更多 → "用其他应用打开" → 选 SmileJar
3. SmileJar 进入前台，弹出 Alert："发现备份文件，是否立即导入此备份？"
4. 点"导入" → 进度中（按钮 disabled，可选加 spinner）→ 完成弹结果摘要
5. 点"取消" → 关闭 Alert，Inbox 临时文件保留（不删，用户可稍后从设置导入）

---

## 不在范围内

- 不支持自定义文件扩展名（如 `.smilejar`）——使用标准 `.zip` 即可
- 不修改 SettingsView 的导入按钮（两个入口并行存在）
- 不添加导入进度条（与 SettingsView 行为一致）
