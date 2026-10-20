import Foundation

struct FormattingInput: Codable, Equatable {
    var title: String
    var segments: [String]      // 正文文字段，按编辑器顺序
}

struct FormattingResult: Codable, Equatable {
    var title: String
    var segments: [String]
}

enum FormattingError: Error, Equatable {
    case llm(LLMError)
    case malformedResponse      // 解析失败或段数不符
}

extension FormattingError {
    var userMessage: String {
        switch self {
        case .llm(let error): return error.userMessage
        case .malformedResponse: return "整理结果格式异常，请重试或换个模型"
        }
    }
}

struct TextFormattingService {
    let client: LLMClient
    let style: FormattingStyle
    let customPrompt: String

    func format(_ input: FormattingInput) async throws -> FormattingResult {
        let reply: String
        do {
            reply = try await client.complete(system: systemPrompt, user: Self.userMessage(for: input))
        } catch let error as LLMError {
            throw FormattingError.llm(error)
        }
        var result = try Self.parse(reply, expectedSegments: input.segments.count)
        // 模型常漏掉段首缩进或段间空行，统一规整一次
        result.segments = result.segments.map(Self.normalizeParagraphs)
        // 预览和写回都用规整后的标题，用户在预览里看到的就是最终写入的
        result.title = Self.normalizeTitle(result.title)
        return result
    }

    /// 标题只能一行：每行去掉首尾空白（含全角缩进），去掉空行，用空格连成一行
    static func normalizeTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static let paragraphIndent = "\u{3000}\u{3000}"

    /// 每个非空行视为一段：去掉首尾空白，段首加两个全角空格，段与段之间空一行
    static func normalizeParagraphs(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { paragraphIndent + $0 }
            .joined(separator: "\n\n")
    }

    var systemPrompt: String {
        [Self.baseRules, styleInstruction, Self.outputFormat].joined(separator: "\n\n")
    }

    private var styleInstruction: String {
        switch style {
        case .light:
            return "整理要求（轻度润色）：" + Self.lightRules
        case .formal:
            return "整理要求（书面化）：先" + Self.lightRules + "再把口语化的表达改为通顺、自然的书面表达。保留全部事实和细节，不添加评论或总结。"
        case .concise:
            return "整理要求（精简）：先" + Self.lightRules + "再删去冗余、绕弯的表述，让文字更简洁。保留关键事实和情感，不添加评论或总结。"
        case .custom:
            return "整理要求：\n" + customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let lightRules = "去掉语气词（如「嗯」「啊」「呃」「那个」「就是说」）、口头禅和无意义的重复；补全标点；改正错别字。保留原意、所有细节和第一人称口吻，不增删事实，不添加评论或总结。"

    private static let baseRules = """
    你是文字整理助手。用户会给你一条生活记录的标题和若干段正文（JSON），请按「整理要求」整理文字。
    规则：
    1. 输出语言与原文保持一致。
    2. 只输出一个 JSON 对象，不要输出任何解释、前后缀或 Markdown 代码块。
    3. segments 中每一项是一个正文块（块与块之间可能夹着照片）。segments 的数量必须与输入完全相同，顺序一一对应；不得合并、拆分、增加或删除正文块。
    4. 输入中为空字符串的正文块，输出也必须是空字符串（第 6 条的情况除外）。
    5. 标题只有一行，不缩进。输入的标题为空时，根据正文拟一个不超过 20 个字的标题；标题和正文都没有实质内容时，标题保持为空字符串。
    6. 标题里误放了正文：用户常常不写标题直接口述，整段内容会落进标题。如果输入的标题明显不是标题，而是一大段正文（比如多句话、在叙述事情经过、远超一般标题的长度），就：
       - 把这段内容按「整理要求」整理后，放到第 1 个正文块（segments 的第一项）的最前面；第 1 个正文块原有内容接在其后，即使原来为空字符串也照此处理；
       - 再根据全部内容另拟一个不超过 20 个字的标题。
       正常的短标题保持为标题，不要挪进正文。
    7. 分段排版（无论哪种整理要求都必须遵守，只在每个正文块内部进行）：
       - 该分段就要分段：按意思合理分段，话题、时间、场景或情绪转换时另起一段；不要把所有内容挤在一段，也不要一句一段。
       - 段与段之间空一行（在 JSON 字符串中用 "\\n\\n" 分隔）。
       - 每段段首缩进两个全角空格「　　」。
    """

    private static let outputFormat = """
    输出格式：
    {"title": "整理后的标题", "segments": ["　　第 1 个正文块的第一段。\\n\\n　　第 1 个正文块的第二段。", "　　第 2 个正文块。"]}
    """

    static func userMessage(for input: FormattingInput) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(input)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 兼容 ```json 代码块包裹、前后夹杂说明文字的回复
    static func parse(_ reply: String, expectedSegments: Int) throws -> FormattingResult {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            } else {
                text = ""
            }
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let result = decode(text) ?? extractObject(from: text).flatMap(decode),
              result.segments.count == expectedSegments
        else { throw FormattingError.malformedResponse }
        return result
    }

    private static func decode(_ text: String) -> FormattingResult? {
        try? JSONDecoder().decode(FormattingResult.self, from: Data(text.utf8))
    }

    private static func extractObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }
}
