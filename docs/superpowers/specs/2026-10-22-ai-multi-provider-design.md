# AI 整理多服务商 设计文档

**日期**：2026-10-22
**背景**：AI 整理原先只保存一套服务商配置（见 `2026-10-18-ai-text-formatting-design.md`），换服务商就要重填地址、模型和 Key。改为类似 cc-switch 的方式：可以配置多个服务商，由用户决定启用哪一个。

---

## 决策摘要

| 项 | 决定 |
|----|------|
| 页面结构 | AI 整理主页列出全部服务商，点一行切换启用；点 ⓘ 进入编辑页；底部「添加服务商」 |
| 初始列表 | 预置 Kimi、DeepSeek、火山方舟（原名豆包，2026-10-22 改名）、OpenAI、Anthropic 各一条，默认启用 Kimi |
| 同一预设 | 可添加多次（如两个 Kimi 账号），名称可改 |
| 整理风格 | 全局一份，所有服务商共用，放在主页 |
| Key 存储 | 每个服务商一条钥匙串记录，账号名 `ai_api_key.<服务商 ID>`；Key 不进 UserDefaults |
| 发送同意 | 仍按主机名记录，不变 |
| 旧版升级 | 首次读取时把旧的那一套（含 Key）合并进列表并启用 |

---

## 改动范围

| 文件 | 类型 | 说明 |
|------|------|------|
| `Smile/Core/AI/AIConfig.swift` | 修改 | `AIConfig` 拆为 `AIProvider`（单个服务商）和 `AISettings`（列表、启用项、风格）；`AIConfigStore` 改为读写 `AISettings`、按服务商存取 Key、迁移旧数据 |
| `Smile/Core/AI/LLMClientFactory.swift` | 修改 | `make` 改为接收 `AIProvider` |
| `Smile/Features/Settings/AISettingsView.swift` | 修改 | 改为服务商列表 + 整理风格 |
| `Smile/Features/Settings/AIProviderEditView.swift` | 新增 | 单个服务商的编辑页 |
| `Smile/Features/EntryEditor/iOSNoteEditorView.swift` | 修改 | `startFormatting` 改用启用中的服务商及其 Key |
| `SmileTests/AIConfigTests.swift` | 修改 | 按新模型重写，补迁移、Key 隔离、删除相关用例 |
| `SmileTests/LLMClientTests.swift` | 修改 | 跟随工厂签名调整 |
| `docs/superpowers/specs/2026-10-18-ai-text-formatting-design.md` | 修改 | 「配置数量」改为指向本文档，从「不做」中移除「多套配置切换」 |

---

## 一、数据模型

```swift
struct AIProvider: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var preset: AIPreset
    var apiProtocol: AIProtocol
    var baseURL: String
    var model: String
}

struct AISettings: Codable, Equatable {
    var providers: [AIProvider]
    var activeProviderID: UUID?
    var style: FormattingStyle
    var customPrompt: String
}
```

- `AIPreset`、`AIProtocol`、`FormattingStyle` 不变。
- 原 `AIConfig` 上与服务商有关的成员搬到 `AIProvider`：`validatedBaseURL`、`trimmedModel`、`consentHost`、`providerDisplayName`，以及 `isComplete(apiKey:)` 中地址、模型、Key 的检查。
- `AIProvider.make(preset:)` 按预设生成一条：名称取 `preset.displayName`，协议、地址、模型取 `preset.defaults`；自定义预设的地址和模型为空、协议为 OpenAI 兼容。
- `AIProvider.applyingPreset(_:)`：换预设时重新填入协议、地址、模型（自定义保留原值，与现在一致）；名称等于旧预设的 `displayName` 时改成新预设的，否则保留用户改过的名称。
- `providerDisplayName`：名称去掉首尾空白后为空、或者是自定义预设且名称仍为「自定义」时，显示主机名（没有主机名时显示「自定义服务商」）；否则显示名称。
- `AISettings.default`：预置 Kimi、DeepSeek、火山方舟、OpenAI、Anthropic 五条（OpenAI 为 2026-10-22 追加，固定 ID 为 …0005），启用 Kimi，风格轻度润色，提示词为空。
- `AISettings.activeProvider`：按 `activeProviderID` 查找，找不到返回 nil。
- `AISettings.isComplete(apiKey:)`：有启用中的服务商、该服务商完整，并且风格为自定义时提示词不为空。
- `AISettings.removingProvider(id:)`：从列表移除；被删的是启用项时改为启用列表第一条，列表空了则为 nil。

## 二、存储与迁移

`AIConfigStore` 对外接口：

- `load() -> AISettings`、`save(_:)`：UserDefaults 键 `ai_settings`，JSON 编码。没有保存过时先尝试迁移，再不行返回 `.default`。
- `loadAPIKey(for id: UUID) -> String?`、`saveAPIKey(_:for:) throws`：钥匙串账号 `ai_api_key.<id>`；传空字符串表示清除。
- `isConfigured`：`load()` 的启用服务商连同它的 Key 是否完整。
- `hasConsent(for:)`、`recordConsent(for:)` 不变。

**旧版迁移**（`load()` 中，`ai_settings` 不存在而旧键 `ai_config` 存在时执行）：

1. 解码旧配置；解码失败视为没有旧数据，返回 `.default`，旧键留着不动。
2. 从 `.default` 出发：旧配置的预设不是自定义时，把旧的协议、地址、模型写进同预设那一条；是自定义时追加一条，名称为「自定义」，协议、地址、模型取旧值。
3. 启用这一条，风格和提示词取旧值。
4. 旧 Key（账号 `ai_api_key`）存在时写到这一条的账号下；写入失败则本次不迁移，直接返回迁移结果但不保存，下次再试。
5. 保存 `ai_settings` 后再删除旧键 `ai_config` 和旧 Key；删除失败不影响使用，残留的旧数据不再被读取。

## 三、界面

**AI 整理主页**（`AISettingsView`）

- 「服务商」分区：每行显示名称，下面一行小字显示模型（为空时显示「未填模型」）；没有 Key 时行尾显示「未填 Key」。启用中的行首打 ✓。
  - 点行：设为启用。
  - 点行尾 ⓘ：进入编辑页。
  - 左滑「删除」：弹确认框，确认后删除该服务商的 Key 和这一条；删 Key 失败时提示「删除失败，请重试」，不删这一条。
- 「添加服务商」：弹出菜单列出全部预设（含自定义），选中后按预设新建一条并直接进入编辑页；列表原本为空时同时设为启用。
- 「整理风格」分区：风格 Picker，选自定义时显示提示词 TextEditor，与现在一样。
- 隐私说明 footer 不变。
- 键盘「完成」按钮、下滑收起键盘沿用现有做法。

**编辑页**（`AIProviderEditView`）

- 依次为：名称、预设、接口协议（仅自定义时显示）、接口地址、模型、API Key、测试连接、删除服务商。
- 名称、地址、模型的提示文字与校验沿用现有页面（非 https 时红字提示；豆包显示模型 ID 说明）。
- 修改即保存；Key 在输入框提交、离开 Key 输入框、点测试连接、离开页面时写入，与现在一致。
- 测试连接测试的是本页这一条，与是否启用无关；结果在配置改动后复位，旧请求的结果丢弃，与现在一致。
- 「删除服务商」：确认后与左滑删除同样处理，并返回主页。

## 四、整理流程

`iOSNoteEditorView.startFormatting`：

- 读取 `AISettings`，取启用中的服务商及其 Key；`settings.isComplete(apiKey:)` 不通过或拿不到 `consentHost` 时，弹出现有的「去设置」提示。
- 同意弹窗的服务商名称用 `providerDisplayName`。
- `LLMClientFactory.make(provider:apiKey:)` 创建 client；风格和提示词取自 `AISettings`。

## 五、测试

`AIConfigTests`（测试注入独立的 UserDefaults suite 与钥匙串 service 名，测试后清理）：

- 默认值：五条预置服务商，启用 Kimi，风格轻度润色
- `AISettings` JSON 存取往返
- 各预设生成的协议、地址、模型
- `applyingPreset`：名称未改过时跟随新预设，改过时保留；自定义保留原地址和模型
- `providerDisplayName`：普通名称、空名称、自定义未改名时显示主机名
- 不同服务商的 Key 互不影响；清除一条不影响另一条；Key 不出现在 UserDefaults
- `removingProvider`：删非启用项、删启用项后启用第一条、删光后为 nil
- `isComplete` / `isConfigured`：无启用项、启用项缺 Key、http 地址、空模型、自定义风格但提示词为空
- 迁移：旧预设为 Kimi 时合并进 Kimi 一条并带上 Key；旧预设为自定义时追加一条；迁移后旧键被删除；`ai_settings` 已存在时不再迁移

`LLMClientTests`：工厂改为接收 `AIProvider`，其余不变。

## 不做

- 服务商排序（拖动调整顺序）
- 每个服务商单独设置整理风格
- 整理时临时选择服务商
- 导入导出服务商配置
