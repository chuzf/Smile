import Foundation

protocol LLMClient {
    func complete(system: String, user: String) async throws -> String
}

enum LLMError: Error, Equatable {
    case notConfigured
    case invalidURL
    case network(String)        // URLError 描述
    case timeout
    case unauthorized           // 401 / 403
    case rateLimited            // 429
    case http(Int, String)      // 其他非 2xx，附响应体前 200 字符
    case emptyResponse
    case truncated              // 输出达到 max_tokens 上限被截断
}

extension LLMError {
    var userMessage: String {
        switch self {
        case .notConfigured, .invalidURL: return "AI 整理配置不完整，请到设置中检查"
        case .network: return "网络连接失败，请检查网络"
        case .timeout: return "模型响应超时，请稍后重试，或换个响应更快的模型"
        case .unauthorized: return "API Key 无效或无权限，请到设置中检查"
        case .rateLimited: return "请求过于频繁或额度不足，请稍后再试"
        case .http(let code, _): return "服务返回错误（状态码 \(code)）"
        case .emptyResponse: return "整理结果格式异常，请重试或换个模型"
        case .truncated: return "整理结果过长被截断，请缩短内容或换个模型"
        }
    }
}

/// 两种协议共用的请求构造与发送
enum LLMHTTP {
    /// 非流式请求在生成完之前不回任何数据，这个空闲超时实际就是总时长上限；思考模型耗时较长
    static let timeout: TimeInterval = 300

    /// 去掉末尾所有的 /
    static func trimmedBase(_ base: URL) -> String {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 拼接端点；用户已填完整端点（以 path 结尾）时不重复拼接
    static func endpoint(_ base: URL, path: String) -> URL? {
        let trimmed = trimmedBase(base)
        return URL(string: trimmed.hasSuffix(path) ? trimmed : trimmed + path)
    }

    static func makeRequest(url: URL, headers: [String: String], body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// 非 2xx 映射为 LLMError；任务取消时抛 CancellationError
    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // 只有任务真被取消才算用户取消；系统层的 -999（鉴权质询、代理等）按网络错误提示，不能静默失败
            if Task.isCancelled { throw CancellationError() }
            throw LLMError.network(error.localizedDescription)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.emptyResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw LLMError.unauthorized
        case 429: throw LLMError.rateLimited
        default:
            throw LLMError.http(http.statusCode, String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
    }
}
