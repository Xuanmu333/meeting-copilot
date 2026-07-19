import Foundation
import Security

struct DeepSeekService {
    let apiKey: String
    let model: String

    func reply(
        transcript: String,
        context: String,
        style: ReplyStyle,
        previousReply: String
    ) async throws -> String {
        let styleInstruction: String
        switch style {
        case .standard:
            styleInstruction = "Write 1-3 short sentences, at most 60 words."
        case .shorter:
            styleInstruction = "Rewrite as one very short sentence."
        case .natural:
            styleInstruction = "Make it sound natural and conversational when spoken aloud."
        case .cautious:
            styleInstruction = "Make no firm commitment unless the supplied documents explicitly support it."
        }

        let input = """
        MEETING TRANSCRIPT:
        \(transcript)

        SELECTED DOCUMENT EXCERPTS:
        \(context.isEmpty ? "No relevant excerpt was found." : context)

        PREVIOUS REPLY:
        \(previousReply.isEmpty ? "None" : previousReply)

        TASK:
        \(styleInstruction)
        """

        return try await request(
            instructions: """
            You are a live English meeting copilot for a Chinese professional.
            Return only the English words the user should say aloud.
            Use simple, easy-to-pronounce business English.
            Never invent dates, numbers, names, decisions, or commitments.
            When facts are unsupported, say that the user needs to confirm and get back later.
            Do not use markdown, labels, quotation marks, or explanations.
            """,
            input: input
        )
    }

    func convertChinese(_ intent: String) async throws -> String {
        try await request(
            instructions: """
            Convert the user's Chinese intent into simple, natural spoken business English.
            Return only 1-3 English sentences the user can read aloud.
            Preserve uncertainty and do not add facts or commitments.
            Do not use markdown, labels, quotation marks, or explanations.
            """,
            input: intent
        )
    }

    func analyzeMeeting(
        utterance: String,
        recentConversation: String,
        documentContext: String
    ) async throws -> MeetingAnalysis {
        let content = try await request(
            instructions: """
            You are a real-time meeting copilot for a Chinese professional.
            Return a JSON object with exactly these fields:
            chinese_translation: a clear Chinese translation of the latest English utterance.
            is_question: true when the speaker asks a question, requests confirmation, asks for a decision, or expects a response.
            suggested_reply: when is_question is true, provide 1-3 short sentences of simple spoken business English; otherwise null.
            Use recent conversation to resolve references and intent.
            Use document excerpts only as factual evidence.
            Never invent dates, numbers, names, decisions, or commitments.
            If facts are unsupported, the reply should say they need to be confirmed.
            """,
            input: """
            RECENT CONVERSATION:
            \(recentConversation.isEmpty ? "None" : recentConversation)

            LATEST ENGLISH UTTERANCE:
            \(utterance)

            RELEVANT DOCUMENT EXCERPTS:
            \(documentContext.isEmpty ? "No relevant excerpt was found." : documentContext)
            """,
            jsonOutput: true
        )

        guard let data = content.data(using: .utf8) else {
            throw CopilotError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(MeetingAnalysis.self, from: data)
        } catch {
            throw CopilotError.invalidResponse
        }
    }

    private func request(
        instructions: String,
        input: String,
        jsonOutput: Bool = false
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": input]
            ],
            "thinking": ["type": "disabled"],
            "max_tokens": 180,
            "stream": false
        ]
        if jsonOutput {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CopilotError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.apiErrorMessage(data) ?? "DeepSeek request failed (\(http.statusCode))."
            throw NSError(domain: "MeetingCopilot.DeepSeek", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.isEmpty else {
            throw CopilotError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func apiErrorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

final class KeychainService {
    private let service = "com.xuanmu.MeetingCopilot"
    private let account = "deepseek-api-key"

    func save(_ value: String) throws {
        delete()
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
