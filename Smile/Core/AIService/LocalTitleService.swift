import Foundation

struct LocalTitleService: AIService {

    func generateTitle(text: String, context: TitleContext) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return Self.firstSentence(from: trimmed, maxChars: 20)
        }
        return Self.dateFallback(date: context.date, groupName: context.groupName)
    }

    static func firstSentence(from text: String, maxChars: Int) -> String {
        let delimiters: Set<Character> = ["。", ".", "！", "!", "？", "?", "\n"]
        var sentence = ""
        for ch in text {
            if delimiters.contains(ch) { break }
            sentence.append(ch)
            if sentence.count >= maxChars { break }
        }
        return sentence.trimmingCharacters(in: .whitespaces)
    }

    static func dateFallback(date: Date, groupName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: date)) · \(groupName)"
    }
}
