# AI 文字整理 设计文档

**日期**：2026-10-18
**背景**：用户希望把记录的标题和正文交给大模型整理，去掉语气词、口头禅等不正式的内容（类似 Typeless）。模型地址和 Key 由用户自行配置，需支持 Kimi、豆包，以及 moacode 等第三方网关上的 Claude Opus。

---

## 决策摘要

| 项 | 决定 |
|----|------|
| 触发方式 | 编辑器工具栏「整理」按钮，手动触发 |
| 应用方式 | 预览 sheet 展示整理结果（可切换原文对比），点「替换」才写回编辑器；不另做撤销 |
| 协议 | OpenAI 兼容（`/chat/completions`）与 Anthropic 兼容（`/v1/messages`）两种都实现 |
| 预设 | Kimi、豆包、Anthropic 官方、自定义（自选协议）；moacode 不内置，用户用「自定义」填写 |
| 配置数量 | 只保存一套 |
| 整理风格 | 轻度润色（默认）/ 书面化 / 精简 / 自定义提示词 |
| 标题 | 标题为空时由 AI 生成；有标题时按所选风格整理 |
| 发送内容 | 仅标题和文字段；不发送照片、视频、语音及语音转写 |
| 照片位置 | 一次调用，按编号发送各文字段，模型按相同段数返回 JSON，写回时一一对应，照片与对齐方式不动 |

---

## 改动范围

| 文件 | 类型 | 说明 |
|------|------|------|
| `Smile/Core/AI/AIConfig.swift` | 新增 | 配置模型、预设、风格；UserDefaults 读写；Key 读写走 Keychain |
| `Smile/Core/AI/LLMClient.swift` | 新增 | `LLMClient` 协议、`LLMError`、按配置创建 client 的工厂 |
| `Smile/Core/AI/OpenAICompatibleClient.swift` | 新增 | OpenAI 兼容实现 |
| `Smile/Core/AI/AnthropicClient.swift` | 新增 | Anthropic 兼容实现 |
| `Smile/Core/AI/TextFormattingService.swift` | 新增 | 组装 prompt、调用 client、解析并校验结果 |
| `Smile/Features/EntryEditor/iOSNoteEditorModel+Formatting.swift` | 新增 | `FormattingSnapshot`、`formattingSnapshot()` / `canFormat` / `applyFormatting(_:to:)` |
| `Smile/Features/EntryEditor/FormattingPreviewSheet.swift` | 新增 | 预览 sheet |
| `Smile/Features/EntryEditor/iOSNoteEditorView.swift` | 修改 | 工具栏按钮、整理中遮罩、错误提示、预览 sheet |
| `Smile/Features/Settings/AISettingsView.swift` | 新增 | 「AI 整理」设置页 |
| `Smile/Features/Settings/SettingsView.swift` | 修改 | 增加进入 AI 整理设置的入口 |
| `README.md` | 修改 | 删掉未实现的「AI 自动标题」，改为本功能说明 |
| `SmileTests/AIConfigTests.swift` | 新增 | 配置持久化、Key 存 Keychain |
| `SmileTests/LLMClientTests.swift` | 新增 | 两个 client 的请求构造与响应解析（URLProtocol 打桩） |
| `SmileTests/TextFormattingServiceTests.swift` | 新增 | prompt 组装、JSON 解析、异常情况 |
| `SmileTests/iOSNoteEditorModelFormattingTests.swift` | 新增 | 写回映射 |

---

## 一、配置（`AIConfig`）

```swift
enum AIProtocol: String, Codable { case openAI, anthropic }

enum AIPreset: String, Codable, CaseIterable {
    case kimi, doubao, anthropic, custom
}

enum FormattingStyle: String, Codable, CaseIterable {
    case light      // 轻度润色（默认）
    case formal     // 书面化
    case concise    // 精简
    case custom     // 自定义提示词
}

struct AIConfig: Codable, Equatable {
    var preset: AIPreset
    var apiProtocol: AIProtocol
    var baseURL: String
    var model: String
    var style: FormattingStyle
    var customPrompt: String
}
```

- **存储**：由 `AIConfigStore`（构造时注入 `UserDefaults` 和 `KeychainService`）负责读写。`AIConfig` 以 JSON 存在 UserDefaults 的 `ai_config` 键下。API Key 存 Keychain，账户名 `ai_api_key`，使用现有 `KeychainService`；严禁写入 UserDefaults。
- **预设**：选中预设会覆盖协议、Base URL，并给出模型名默认值。模型名始终可以修改，实现时按各家官方文档核对默认值。

| 预设 | 协议 | Base URL | 模型名 |
|------|------|----------|--------|
| Kimi | openAI | `https://api.moonshot.cn/v1` | `kimi-k2.6` |
| 豆包 | openAI | `https://ark.cn-beijing.volces.com/api/v3` | 留空，用户填方舟模型 ID 或接入点 ID |
| Anthropic | anthropic | `https://api.anthropic.com` | `claude-opus-5` |
| 自定义 | 用户选择 | 用户填写 | 用户填写 |

- **是否已配置**（`isConfigured`）：Base URL 能解析，且 scheme 为 `https`；模型名非空；Keychain 里有非空 Key。风格为「自定义」时，自定义提示词也必须非空。
- 默认配置：预设 Kimi，风格轻度润色。

## 二、网络层

```swift
protocol LLMClient {
    func complete(system: String, user: String) async throws -> String
}

enum LLMError: Error, Equatable {
    case notConfigured
    case invalidURL
    case network(String)        // URLError 描述
    case unauthorized           // 401 / 403
    case rateLimited            // 429
    case http(Int, String)      // 其他非 2xx，附响应体前 200 字符
    case emptyResponse
}
```

两个实现都通过构造器注入 `URLSession`，默认 `.shared`。请求超时 300 秒（非流式请求生成完才回数据，思考模型耗时较长）；`URLError.timedOut` 映射为 `LLMError.timeout`，输出达到上限（OpenAI `finish_reason == "length"`、Anthropic `stop_reason == "max_tokens"`）映射为 `LLMError.truncated`。用户填的地址已是完整端点时不重复拼接路径。**不传 `temperature`**：Claude Opus 4.7+ / Opus 5 / Sonnet 5 会对采样参数返回 400，部分第三方网关会把 OpenAI 协议转发到这些模型。

**`OpenAICompatibleClient`**
- 请求 `POST {baseURL 去掉末尾 /}/chat/completions`
- 请求头：`Authorization: Bearer {key}`、`Content-Type: application/json`
- 请求体：`{"model", "messages": [{"role":"system",...},{"role":"user",...}]}`
- 取 `choices[0].message.content`

**`AnthropicClient`**
- 路径：baseURL 去掉末尾的 `/`；如果已经以 `/v1` 结尾，就拼接 `/messages`，否则拼接 `/v1/messages`
- 请求头：`x-api-key: {key}`、`anthropic-version: 2023-06-01`、`Content-Type: application/json`；host 不是 `api.anthropic.com` 时另加 `Authorization: Bearer {key}`（不少网关按 Bearer 鉴权）
- 请求体：`{"model", "max_tokens": 16000, "system", "messages": [{"role":"user",...}]}`；不传 `thinking`，由模型默认行为决定
- 把 `content` 中所有 `type == "text"` 的块拼接起来（忽略 `thinking` 等其他块）；拼接结果为空（包括 `stop_reason == "refusal"`）时抛 `emptyResponse`

工厂方法 `LLMClientFactory.make(config:key:session:) -> LLMClient` 按 `apiProtocol` 返回对应实现。

## 三、整理服务（`TextFormattingService`）

```swift
struct FormattingInput: Equatable {
    var title: String
    var segments: [String]      // 正文文字段，按编辑器顺序
}

struct FormattingResult: Equatable {
    var title: String
    var segments: [String]
}

enum FormattingError: Error, Equatable {
    case llm(LLMError)
    case malformedResponse      // 解析失败或段数不符
}

struct TextFormattingService {
    let client: LLMClient
    let style: FormattingStyle
    let customPrompt: String
    func format(_ input: FormattingInput) async throws -> FormattingResult
}
```

- **system prompt** 由三部分组成：
  1. 通用规则：输出语言与原文一致；只输出 JSON；`segments` 数量必须与输入相同且顺序一致；某段为空时原样返回空字符串；标题为空时根据正文拟一个不超过 20 字的标题。
  2. 风格指令：
     - 轻度润色：去掉语气词（嗯、啊、那个、就是说……）、口头禅和无意义的重复，补全标点，合理分段，改正错别字；保留原意、细节和第一人称口吻，不增删事实，不加评论
     - 书面化：在轻度润色的基础上改为通顺的书面表达，保留全部事实
     - 精简：在轻度润色的基础上删去冗余表述，保留关键事实和情感
     - 自定义：使用用户填写的 `customPrompt`
  3. 输出格式说明：`{"title": "...", "segments": ["...", ...]}`
- **user 消息**：把 `FormattingInput` 编码成 `{"title": "...", "segments": [...]}` 的 JSON 字符串。
- **解析**：
  - 先去掉首尾空白，再剥掉 ```json … ``` 或 ``` … ``` 代码块包裹
  - 若仍不是合法 JSON，截取第一个 `{` 到最后一个 `}` 之间的内容再试一次
  - 解码失败，或 `segments.count != input.segments.count`，抛 `malformedResponse`
- 输入的标题和所有段都为空时，不发请求，按钮本身应已不可用。

## 四、编辑器

### 模型（`iOSNoteEditorModel`）

放在新文件 `iOSNoteEditorModel+Formatting.swift` 的 extension 里，只使用公开的 `segments`。

```swift
struct FormattingSnapshot: Equatable {
    let input: FormattingInput
    let textSegmentIDs: [UUID]   // 与 input.segments 一一对应；[0] 是承载标题的首个文字段
    let layout: [Block]          // 编辑器中文字段与照片的排列，供预览显示「［照片］」占位
    enum Block: Equatable { case text(Int), photo }
}
```

- `formattingSnapshot() -> FormattingSnapshot?`
  - 没有任何文字段时返回 nil
  - 标题：等同 `extractTitle()`，即第一个文字段的第一行
  - segments：第一个文字段去掉首行后的剩余部分作为第 0 段（可以为空字符串），其后每个 `.text` 段依次各占一段
  - 用值类型快照记录段与 segment id 的对应关系，不在模型里保存隐藏状态
- `canFormat: Bool`：快照存在，且标题或任一段去掉空白后非空
- `applyFormatting(_ result: FormattingResult, to snapshot: FormattingSnapshot) -> Bool`
  - 段数与快照不符，或快照中任一 id 已不在 `segments` 中：不做任何修改，返回 `false`
  - 首个文字段的内容改为：`result.title`（其中的换行替换为空格），若 `result.segments[0]` 非空，再接 `"\n" + result.segments[0]`
  - 其余文字段按 id 替换内容
  - 照片段、对齐方式、语音附件都不变
  - 设置 `isDirty = true`，返回 `true`；正常情况下由遮罩保证整理期间编辑器不会被改动

### 视图（`iOSNoteEditorView`）

- **工具栏**：在「标签」之后加「整理」按钮（`wand.and.stars`，文案「整理」），样式与其他按钮一致。
  - 不可用：听写进行中，或 `model.canFormat == false`
  - 未配置时点击：弹窗「尚未配置 AI 整理」，按钮为 [去设置] / [取消]。「去设置」以 sheet 打开 `AISettingsView`
- **整理中**：编辑器上方覆盖半透明遮罩，显示 `ProgressView` 和「整理中…」，带「取消」按钮；取消时 cancel 掉请求 Task。遮罩挡住所有编辑操作。
- **成功**：弹出 `FormattingPreviewSheet`。
  - 顶部有分段控件「整理后 / 原文」
  - 内容区显示标题和各段文字，段与段之间用分隔线隔开；照片位置用「［照片］」占位，帮助用户对照
  - 导航栏按钮为 [取消] / [替换]；点「替换」调用 `applyFormatting` 并关闭 sheet；返回 false 时提示「内容已变化，未能替换，请重新整理。」
- 整理中、预览、整理相关弹窗显示期间，计入 `isPresentingOther`，分享照片的询问等它们结束后再弹
- **失败**：弹出 alert「整理失败」，文案如下：

| 错误 | 文案 |
|------|------|
| `unauthorized` | API Key 无效或无权限，请到设置中检查 |
| `rateLimited` | 请求过于频繁或额度不足，请稍后再试 |
| `network` | 网络连接失败，请检查网络 |
| `http` | 服务返回错误（状态码 N） |
| `malformedResponse` / `emptyResponse` | 整理结果格式异常，请重试或换个模型 |
| `invalidURL` / `notConfigured` | AI 整理配置不完整，请到设置中检查 |

## 五、设置页（`AISettingsView`）

在 `SettingsView` 新增「AI」分区，放一个 NavigationLink「AI 整理」进入本页。表单内容：

- **服务商**：Picker（Kimi / 豆包 / Anthropic / 自定义），切换时按预设填好协议、地址和模型
- **接口协议**：Picker（OpenAI 兼容 / Anthropic 兼容），仅「自定义」时显示
- **接口地址**：TextField，关闭自动大写和自动纠错，键盘类型为 URL；非 https 时显示红字提示
- **模型**：TextField
- **API Key**：SecureField。进入页面时若已有 Key，显示「已保存」占位；输入新值后保存覆盖。另有「清除 Key」按钮
- **整理风格**：Picker；选「自定义」时显示 TextEditor 填写提示词
- **测试连接**：用当前表单值发送一条极短请求（system 为「回复 OK」，user 为「ping」），根据结果显示「连接成功」或对应错误文案
- **隐私说明**（Section footer）：「整理时会把标题和正文文字发送给你配置的服务商，不发送照片、视频和语音。API Key 仅保存在本机钥匙串。」

配置在每次修改时保存（`onChange(of: config)`），Key 在输入框提交、点「测试连接」或离开页面时写入 Keychain。

## 六、测试

- **`AIConfigTests`**：默认值；JSON 存取往返；各预设的协议和地址；`isConfigured` 的各种边界（http 地址、空模型、无 Key、自定义风格但提示词为空）；Key 写入 Keychain 而不在 UserDefaults（测试注入独立的 Keychain service 名和 UserDefaults suite，测试后清理）
- **`LLMClientTests`**：用 `URLProtocol` 桩拦截请求
  - 两种 client 的 URL 拼接，包括 Anthropic base 带不带 `/v1`、末尾带不带 `/`
  - 请求头和请求体字段
  - 成功响应的解析
  - 401、429、500 和空 content 映射到对应的 `LLMError`
- **`TextFormattingServiceTests`**：用假 `LLMClient`
  - 各风格的 system prompt 包含对应指令
  - user 消息是合法 JSON
  - 解析纯 JSON、```json 包裹、前后有说明文字三种情况
  - 段数不符、非 JSON 时抛 `malformedResponse`
- **`iOSNoteEditorModelFormattingTests`**：
  - 「标题 + 正文 + 照片 + 文字」的结构，`formattingSnapshot()` 的拆分是否正确
  - 段数不符或 segment 已被删除时，`applyFormatting` 返回 false 且不修改内容
  - `applyFormatting` 后照片段位置、对齐方式不变，标题行被替换
  - 首段只有标题、整理结果第 0 段为空时，不产生多余的换行

## 不做

- 多套配置切换
- 替换后的撤销（预览确认已承担这个作用）
- 流式输出
- 整理语音转写
- 保存时自动整理
