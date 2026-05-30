import Foundation

struct ClaudeAIService: AIService {
    let apiKey: String
    let model: String
    let timeoutSeconds: TimeInterval
    let session: URLSession

    init(
        apiKey: String,
        model: String = "claude-haiku-4-5-20251001",
        timeoutSeconds: TimeInterval = 5,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.session = session
    }

    func generateTitle(text: String, context: TitleContext) async throws -> String {
        guard !apiKey.isEmpty else { throw AIServiceError.noAPIKey }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        let dateStr = formatter.string(from: context.date)

        let prompt = """
        你是一款记录温暖瞬间的 App。请为下面这段记录生成一个不超过 15 字的中文标题,\
        风格温柔、具象、不煽情。分组是"\(context.groupName)",日期是 \(dateStr)。

        记录内容:
        \(text)

        只回标题本身,不要任何解释、引号或标点结尾。
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 64,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIServiceError.network(error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIServiceError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String
        else {
            throw AIServiceError.invalidResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                   .replacingOccurrences(of: "\"", with: "")
    }
}
