import Foundation

actor LocalWhisperService {
    private let port = 18_178
    private let binaryURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-server")
    private let modelURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeetingCopilot/Models/ggml-large-v3-turbo.bin")
    private var process: Process?
    private var previousTranscript = ""

    deinit {
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func start() async throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw NSError(
                domain: "MeetingCopilot.Whisper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "whisper-server is missing. Install it with: brew install whisper-cpp"]
            )
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NSError(
                domain: "MeetingCopilot.Whisper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "The large-v3-turbo Whisper model has not finished downloading."]
            )
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--language", "en",
            "--threads", "8",
            "--processors", "1",
            "--no-timestamps",
            "--suppress-nst"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process

        for _ in 0..<120 {
            if !process.isRunning {
                throw NSError(
                    domain: "MeetingCopilot.Whisper",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Local Whisper stopped while loading the model."]
                )
            }
            if await isReady() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        process.terminate()
        throw NSError(
            domain: "MeetingCopilot.Whisper",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Local Whisper took too long to load."]
        )
    }

    func transcribe(fileURL: URL) async throws -> String {
        try await start()
        let boundary = "MeetingCopilot-\(UUID().uuidString)"
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/inference")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try multipartBody(
            boundary: boundary,
            audioURL: fileURL,
            prompt: previousTranscript
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "MeetingCopilot.Whisper",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The local Whisper server rejected the audio segment."]
            )
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw CopilotError.invalidResponse
        }
        previousTranscript = String(text.suffix(400))
        return text
    }

    private func isReady() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 0.2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private func multipartBody(
        boundary: String,
        audioURL: URL,
        prompt: String
    ) throws -> Data {
        var data = Data()
        func append(_ string: String) {
            data.append(Data(string.utf8))
        }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        field("response_format", "json")
        field("language", "en")
        field("temperature", "0")
        if !prompt.isEmpty {
            field("prompt", prompt)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        data.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")
        return data
    }
}
