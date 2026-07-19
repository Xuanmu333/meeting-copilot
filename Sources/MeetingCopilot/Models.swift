import Foundation

struct MeetingDocument: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let text: String

    var name: String { url.lastPathComponent }
}

struct MeetingAnalysis: Decodable {
    let chineseTranslation: String
    let isQuestion: Bool
    let suggestedReply: String?

    enum CodingKeys: String, CodingKey {
        case chineseTranslation = "chinese_translation"
        case isQuestion = "is_question"
        case suggestedReply = "suggested_reply"
    }
}

enum ReplyStyle: String, CaseIterable {
    case standard = "Standard"
    case shorter = "Shorter"
    case natural = "More natural"
    case cautious = "More cautious"
}

enum CopilotError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case noDisplay
    case unsupportedDocument

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your DeepSeek API key in Settings first."
        case .invalidResponse:
            return "The model returned an unreadable response."
        case .noDisplay:
            return "No display is available for system audio capture."
        case .unsupportedDocument:
            return "This document could not be read."
        }
    }
}
