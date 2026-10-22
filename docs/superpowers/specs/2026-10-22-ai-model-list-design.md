# 从服务商拉取模型列表 设计文档

**日期**：2026-10-22
**背景**：服务商编辑页的「模型」只能手动填写，用户得自己去官网查模型名。改为可以从服务商拉取模型列表来选，同时保留手动填写。四家预置服务商（Kimi `/v1/models`、DeepSeek `/models`、豆包 `/api/v3/models`、Anthropic `/v1/models`）都有列出模型的接口，均需 Key。

---

## 决策摘要

| 项 | 决定 |
|----|------|
| 界面 | 模型仍是输入框，右侧加「选择」按钮，点了弹出带搜索的模型列表，点一个填入输入框 |
| 拉取时机 | 每次点「选择」都重新拉取；不缓存、不写入设置 |
| 使用的配置 | 编辑页当前的协议、地址和该服务商的 Key（先保存刚输入的 Key，同测试连接） |
| 顺序 | 保持服务商返回的顺序，去重 |
| 手动填写 | 不变；豆包的「填接入点 ID」说明保留 |

---

## 改动范围

| 文件 | 类型 | 说明 |
|------|------|------|
| `Smile/Core/AI/LLMClient.swift` | 修改 | `LLMHTTP.makeGetRequest`；`LLMHTTP.modelListTimeout` |
| `Smile/Core/AI/OpenAICompatibleClient.swift` | 修改 | `modelsEndpoint`、`listModels()` |
| `Smile/Core/AI/AnthropicClient.swift` | 修改 | `modelsEndpoint`、`listModels()`（分页） |
| `Smile/Core/AI/LLMClientFactory.swift` | 修改 | `listModels(provider:apiKey:session:)` |
| `Smile/Features/Settings/ModelPickerSheet.swift` | 新增 | 选择模型的 sheet |
| `Smile/Features/Settings/AIProviderEditView.swift` | 修改 | 模型行加「选择」按钮，弹出 sheet |
| `SmileTests/LLMClientTests.swift` | 修改 | 拉取模型的请求构造、解析、分页、错误 |

---

## 一、拉取接口

`LLMClient` 协议不变（测试里的假 client 不受影响），两个具体 client 各加一个方法：

```swift
func listModels() async throws -> [String]
```

**通用**

- `LLMHTTP.makeGetRequest(url:headers:)`：GET，超时 `modelListTimeout = 30` 秒（列模型很快，不用整理文字的 300 秒）。
- 发送和状态码映射复用 `LLMHTTP.send`：401/403 → `unauthorized`，429 → `rateLimited`，其他非 2xx → `http`。
- 响应无法解析时抛 `emptyResponse`。
- 结果去掉首尾空白和空串，按首次出现去重，保持原顺序。

**OpenAI 兼容**

- `modelsEndpoint`：地址去掉末尾 `/`；以 `/chat/completions` 结尾时先去掉这一段；再用 `LLMHTTP.endpoint(_, path: "/models")` 拼接（已以 `/models` 结尾时不重复）。
- 头：`Authorization: Bearer <key>`。
- 响应 `{"data": [{"id": "..."}]}`，取各项 `id`。

**Anthropic 兼容**

- `modelsEndpoint`：地址去掉末尾 `/`；以 `/v1/messages` 结尾时去掉 `/messages`；以 `/v1` 结尾时拼 `/models`，否则拼 `/v1/models`。
- 头：与发消息相同的 `headers`（`x-api-key`、`anthropic-version`，非官方地址另带 Bearer）。
- 请求带 `limit=1000`；响应 `{"data": [{"id": ...}], "has_more": Bool, "last_id": String?}`。`has_more` 为 true 且有 `last_id` 时带 `after_id=<last_id>` 继续请求，最多 5 页。

**工厂**

```swift
static func listModels(provider: AIProvider, apiKey: String, session: URLSession = .shared) async throws -> [String]
```

- 地址不合法抛 `invalidURL`；Key 为空抛 `notConfigured`。不要求已填模型。
- 按协议构造 client（`model` 传空串）并调用 `listModels()`。

## 二、界面

**编辑页模型行**：`HStack { TextField("模型", …); Button("选择") }`，按钮 `.buttonStyle(.borderless)`，避免整行可点。点按钮：

1. 收起键盘，`saveKeyIfNeeded()`；失败时不弹出（Key 区已显示错误）。
2. 弹出 `ModelPickerSheet`，传入当前服务商快照和 Key（可能为 nil），以及选中回调。

**`ModelPickerSheet`**

- `NavigationStack` 内的 `List`，标题「选择模型」，左上角「取消」，`.searchable` 按包含匹配、不区分大小写过滤。
- 出现时拉取（`.task`）；状态：
  - 拉取中：居中 `ProgressView`。
  - 缺 Key 或地址不合法：「请先填写接口地址和 API Key」，不发请求。
  - 失败：错误文案（`LLMError.userMessage`，`http` 时附响应体，同测试连接）和「重试」按钮。
  - 空列表：「服务商没有返回模型，请手动填写」。
  - 成功：每行一个模型名，与当前模型相同的打 ✓；点一行回调填入并关闭。
- 关闭 sheet 时 `.task` 自动取消请求，取消不提示错误。

## 三、测试

`LLMClientTests`（用现有 `StubURLProtocol`）：

- OpenAI：`modelsEndpoint` 对 `…/v1`、`…/v1/`、`…/v1/chat/completions`、`…/v1/models` 的结果；请求为 GET、带 Bearer；解析 `data[].id`、去重、去空
- Anthropic：`modelsEndpoint` 对 `https://api.anthropic.com`、`…/v1`、`…/v1/messages` 的结果；带 `x-api-key`、`anthropic-version`、`limit=1000`；`has_more` 时第二页带 `after_id`；一直 `has_more` 时只请求 5 次
- 401 → `unauthorized`；非 JSON → `emptyResponse`
- 工厂：Key 为空抛 `notConfigured`，http 地址抛 `invalidURL`，模型为空也能拉取

## 不做

- 缓存模型列表
- 显示模型详情（上下文长度、价格等）
- 进入编辑页时自动拉取
