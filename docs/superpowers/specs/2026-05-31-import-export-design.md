# 导入/导出功能设计文档

**日期**：2026-05-31  
**状态**：待审阅

---

## 背景与目标

SmileJar 已有导出功能（`ExportService.exportAll`），将所有数据打包为 `.zip` 文件并通过系统分享面板发送。本次目标：

1. **修复导出功能的已知问题**：失败时静默丢弃错误，用户无任何提示
2. **新增导入功能**：将 A 手机导出的 `.zip` 包导入到 B 手机，支持增量合并

---

## 导出功能问题修复

### 问题

`SettingsView.exportAll()` 在导出失败时仅调用 `print("导出失败: \(error)")`，用户界面无任何反馈。

### 修复

在 `SettingsView` 中增加 `@State private var exportError: String?`，失败时赋值并通过 `.alert` 展示给用户。

---

## 导入功能设计

### 入口

在 `SettingsView` 的"数据"Section 中，"导出全部记录"按钮下方增加"导入备份"按钮：

```
数据 Section
├── 导出全部记录   [导出中... spinner]
└── 导入备份       [导入中... spinner]
```

点击"导入备份"触发 `.fileImporter(allowedContentTypes: [.zip])`，用户从 Files 或 AirDrop 选择 `.zip` 文件后开始导入。

### 技术依赖

添加 **ZIPFoundation** SPM 包（`https://github.com/weichsel/ZIPFoundation`，版本 `~> 0.9`）用于解压 zip 文件。项目已有 SPM 配置（现有 `swift-snapshot-testing`），添加方式一致。

### 新增文件

**`Smile/Core/Import/ImportService.swift`**

### 数据结构

```swift
struct ImportResult {
    let newGroups: Int
    let newEntries: Int
    let updatedEntries: Int   // A 更新了、覆盖了 B 的条目
    let skippedEntries: Int   // B 版本更新或相同，跳过
    let newTags: Int
}

enum ImportError: Error {
    case unsupportedVersion(Int)
    case invalidManifest
    case missingRequiredFile(String)
}
```

### 导入流程

1. **解压**：将 zip 解压到临时目录（`FileManager.temporaryDirectory/smilejar-import-<UUID>/`）
2. **校验 manifest**：读取 `manifest.json`，检查 `version` 字段，当前仅支持 v1，遇到高版本抛出 `ImportError.unsupportedVersion`
3. **解码 JSON**：解码 `groups.json`、`entries.json`、`tags.json`
4. **加载现有数据**：从 `ModelContext` fetch 所有 Group、Entry、Tag
5. **处理分组**（建立 UUID 映射表）
6. **处理标签**
7. **处理条目**（逐条检查 UUID，按策略插入/覆盖/跳过）
8. **复制媒体文件**
9. **保存 context**，清理临时目录
10. **返回 `ImportResult`**

### 合并策略详述

#### 分组合并（建立 `groupIDMap: [UUID: UUID]`）

| 条件 | 操作 |
|------|------|
| `isBuiltIn: true`，按名称找到 B 上同名分组 | 不插入，记录 `exportUUID → existingUUID` |
| `isBuiltIn: true`，B 上不存在同名分组 | 插入，记录 `exportUUID → exportUUID` |
| `isBuiltIn: false`，UUID 已存在于 B | 不插入，记录 `exportUUID → exportUUID` |
| `isBuiltIn: false`，UUID 不存在于 B | 插入，记录 `exportUUID → exportUUID` |

> **关键**：即使分组已存在（跳过插入），仍需记录映射，确保该分组下的新条目能正确关联到 B 上的对应分组。

#### 标签合并

- Tag 以 `name` 为唯一键
- 按 name 查找：已存在 → 跳过插入，但保留对象引用供条目使用；不存在 → 插入

#### 条目合并（核心逻辑）

条目合并独立于分组是否被跳过，对导入包中的每条 Entry 逐一处理：

| 条件 | 操作 |
|------|------|
| UUID 不存在于 B | 插入新条目，通过 `groupIDMap` 解析 `groupID`；若映射不存在则置 `group = nil` |
| UUID 已存在，A 的 `updatedAt` > B 的 `updatedAt` | 用 A 的版本覆盖条目字段和媒体目录，计入 `updatedEntries` |
| UUID 已存在，A 的 `updatedAt` ≤ B 的 `updatedAt` | 跳过，计入 `skippedEntries` |

#### 媒体文件处理

- **新增条目**：若 zip 中存在 `media/<entryUUID>/` 目录，复制到 `MediaStore`
- **覆盖条目**：完整替换 B 上的 `media/<entryUUID>/` 目录（先删除再复制），确保媒体文件与条目的 `attachments` 列表一致
- **跳过的条目**：不操作媒体文件

### 用户反馈

**成功**（Alert）：
> 导入完成：新增 X 条记录（其中更新 X 条）、X 个分组、X 个标签，跳过 X 条已有记录

**失败**（Alert）：
> 导入失败：[错误描述]

---

## 备份格式说明（v1，不变）

导出包结构不变，ImportService 按此解析：

```
smilejar-backup-YYYY-MM-DD.zip
├── manifest.json       { version, exportedAt, groupCount, entryCount }
├── groups.json         GroupDTO[]
├── entries.json        EntryDTO[]
├── tags.json           TagDTO[]
└── media/
    └── <entryUUID>/
        └── <filename>
```

---

## 测试范围

| 场景 | 期望结果 |
|------|---------|
| 空 B 机导入完整备份 | 全部条目、分组、标签、媒体文件导入 |
| B 已有部分数据，导入含新增条目的备份 | 仅新增条目被导入，已有条目跳过 |
| 导入相同备份两次 | 第二次全部跳过，数据不重复 |
| A 有更新条目（updatedAt 更新），重新导入 | 条目被覆盖，媒体目录被替换 |
| B 上修改了某条目，导入旧备份 | 跳过该条目（B 的版本更新） |
| 内置分组条目跨设备导入 | 内置分组按名称匹配，条目正确归属 |
| 导入非 v1 格式备份 | 弹出提示：不支持该备份版本 |
| 导出时发生错误 | Alert 显示错误信息 |
