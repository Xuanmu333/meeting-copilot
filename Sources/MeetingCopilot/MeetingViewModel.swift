import AppKit
import Foundation

@MainActor
final class MeetingViewModel: ObservableObject {
    @Published var documents: [MeetingDocument] = []
    @Published var transcript = ""
    @Published var chineseTranslation = ""
    @Published var suggestedReply = ""
    @Published var replySource = ""
    @Published var status = "Ready"
    @Published var isListening = false
    @Published var isGenerating = false
    @Published var errorMessage = ""
    @Published var isShowingError = false
    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: "modelName") }
    }
    @Published private(set) var hasAPIKey = false

    private let documentService = DocumentService()
    private let keychain = KeychainService()
    private let captureService = SystemAudioCaptureService()
    private var recentConversation: [String] = []
    private var lastAnalyzedTranscript = ""
    private var analysisTask: Task<Void, Never>?

    init() {
        let storedModel = UserDefaults.standard.string(forKey: "modelName")
        modelName = storedModel?.hasPrefix("deepseek-") == true
            ? storedModel!
            : "deepseek-v4-flash"
        hasAPIKey = keychain.read() != nil
        captureService.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if isFinal {
                    let separator = self.transcript.isEmpty ? "" : " "
                    self.transcript += separator + text
                } else {
                    self.transcript = text
                }
                self.status = isFinal ? "Understanding the speaker…" : "Listening to Webex…"
                self.scheduleAutomaticAnalysis(for: self.transcript, immediately: isFinal)
            }
        }
        captureService.onError = { [weak self] message in
            Task { @MainActor in self?.showError(message) }
        }
    }

    func toggleMeeting() async {
        if isListening {
            captureService.stop()
            analysisTask?.cancel()
            isListening = false
            status = "Meeting ended"
            return
        }

        do {
            status = "Loading local Whisper and requesting system audio permission…"
            try await captureService.start()
            isListening = true
            status = "Listening to Webex…"
        } catch {
            showError(error.localizedDescription)
            status = "Could not start"
        }
    }

    func importDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentService.supportedTypes
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            Task { @MainActor in
                for url in panel.urls where !self.documents.contains(where: { $0.url == url }) {
                    do {
                        let document = try self.documentService.load(url)
                        self.documents.append(document)
                    } catch {
                        self.showError("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                self.status = "\(self.documents.count) meeting file(s) ready"
            }
        }
    }

    func remove(_ document: MeetingDocument) {
        documents.removeAll { $0.id == document.id }
    }

    func generateReply(style: ReplyStyle) async {
        let currentTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentTranscript.isEmpty else { return }

        await runGeneration {
            let matches = DocumentRetriever.retrieve(query: currentTranscript, documents: documents)
            let context = matches.map { "[\($0.document.name)]\n\($0.excerpt)" }.joined(separator: "\n\n")
            let service = DeepSeekService(apiKey: try requiredAPIKey(), model: modelName)
            let reply = try await service.reply(
                transcript: currentTranscript,
                context: context,
                style: style,
                previousReply: suggestedReply
            )
            suggestedReply = reply
            replySource = matches.isEmpty
                ? "General response — not found in meeting files"
                : "Source: " + matches.map(\.document.name).joined(separator: ", ")
        }
    }

    private func scheduleAutomaticAnalysis(for text: String, immediately: Bool) {
        analysisTask?.cancel()
        analysisTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(for: .seconds(1.2))
            }
            guard !Task.isCancelled, let self else { return }
            await self.analyzeLatestTranscript(text)
        }
    }

    private func analyzeLatestTranscript(_ fullText: String) async {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed != lastAnalyzedTranscript, !isGenerating else { return }

        let utterance: String
        if !lastAnalyzedTranscript.isEmpty, trimmed.hasPrefix(lastAnalyzedTranscript) {
            utterance = String(trimmed.dropFirst(lastAnalyzedTranscript.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            utterance = trimmed
        }
        guard utterance.count >= 3 else { return }

        isGenerating = true
        status = "Translating and checking for a question…"
        defer { isGenerating = false }

        do {
            let matches = DocumentRetriever.retrieve(query: utterance, documents: documents)
            let documentContext = matches
                .map { "[\($0.document.name)]\n\($0.excerpt)" }
                .joined(separator: "\n\n")
            let service = DeepSeekService(apiKey: try requiredAPIKey(), model: modelName)
            let analysis = try await service.analyzeMeeting(
                utterance: utterance,
                recentConversation: recentConversation.joined(separator: "\n\n"),
                documentContext: documentContext
            )
            guard !Task.isCancelled else { return }

            lastAnalyzedTranscript = trimmed
            chineseTranslation = analysis.chineseTranslation
            recentConversation.append(
                "English: \(utterance)\nChinese: \(analysis.chineseTranslation)"
            )
            recentConversation = Array(recentConversation.suffix(6))

            if analysis.isQuestion,
               let reply = analysis.suggestedReply?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reply.isEmpty {
                suggestedReply = reply
                replySource = matches.isEmpty
                    ? "Question detected · General response"
                    : "Question detected · Source: " + matches.map(\.document.name).joined(separator: ", ")
                status = "Question detected — reply ready"
            } else {
                suggestedReply = ""
                replySource = "No direct question detected"
                status = "Chinese translation ready"
            }
        } catch is CancellationError {
            return
        } catch {
            showError(error.localizedDescription)
            status = "Automatic analysis failed"
        }
    }

    func convertChineseIntent(_ intent: String) async {
        await runGeneration {
            let service = DeepSeekService(apiKey: try requiredAPIKey(), model: modelName)
            suggestedReply = try await service.convertChinese(intent)
            replySource = "Converted from your Chinese intent"
        }
    }

    func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.save(trimmed)
            hasAPIKey = true
            status = "API key saved securely"
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removeAPIKey() {
        keychain.delete()
        hasAPIKey = false
        status = "API key removed"
    }

    private func runGeneration(_ operation: () async throws -> Void) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        do {
            try await operation()
            status = "Reply ready"
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func requiredAPIKey() throws -> String {
        guard let key = keychain.read(), !key.isEmpty else {
            throw CopilotError.missingAPIKey
        }
        return key
    }

    private func showError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }

}
