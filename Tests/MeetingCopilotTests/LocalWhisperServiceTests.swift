import XCTest
@testable import MeetingCopilot

final class LocalWhisperServiceTests: XCTestCase {
    func testTranscribesKnownEnglishAudio() async throws {
        let model = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/MeetingCopilot/Models/ggml-large-v3-turbo.bin"
            )
        let binary = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-server")
        let audio = URL(
            fileURLWithPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp/jfk.wav"
        )

        guard FileManager.default.fileExists(atPath: model.path),
              FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.fileExists(atPath: audio.path) else {
            throw XCTSkip("Local Whisper runtime is not installed.")
        }

        let service = LocalWhisperService()
        let transcript = try await service.transcribe(fileURL: audio)

        XCTAssertTrue(transcript.lowercased().contains("fellow americans"))
        XCTAssertTrue(transcript.lowercased().contains("your country"))
    }
}
