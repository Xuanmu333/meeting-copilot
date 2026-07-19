import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let whisper = LocalWhisperService()
    private let chunkWriter = AudioChunkWriter()
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "MeetingCopilot.system-audio")

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw NSError(
                domain: "MeetingCopilot.ScreenCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Allow Meeting Copilot in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen the app."]
            )
        }

        try await whisper.start()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CopilotError.noDisplay }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            },
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        if let finalChunk = chunkWriter.finish() {
            transcribe(finalChunk)
        }
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let buffer = sampleBuffer.audioPCMBuffer else { return }

        do {
            if let completedChunk = try chunkWriter.append(buffer) {
                transcribe(completedChunk)
            }
        } catch {
            onError?("Could not prepare audio for Whisper: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("System audio capture stopped: \(error.localizedDescription)")
    }

    private func transcribe(_ fileURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let text = try await whisper.transcribe(fileURL: fileURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !Self.isNonSpeech(text) {
                    onTranscript?(text, true)
                }
            } catch {
                onError?("Local Whisper transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private static func isNonSpeech(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]() .,!"))
        return normalized.isEmpty ||
            normalized == "music" ||
            normalized == "silence" ||
            normalized == "blank audio"
    }
}

private final class AudioChunkWriter {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private let targetFrames: AVAudioFramePosition = 16_000 * 5
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var fileURL: URL?

    func append(_ input: AVAudioPCMBuffer) throws -> URL? {
        if file == nil {
            try beginChunk()
        }
        if converter == nil || inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
            inputFormat = input.format
        }
        guard let converter else {
            throw NSError(
                domain: "MeetingCopilot.Audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported system audio format."]
            )
        }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw NSError(
                domain: "MeetingCopilot.Audio",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio buffer."]
            )
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? NSError(
                domain: "MeetingCopilot.Audio",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."]
            )
        }

        try file?.write(from: output)
        if let file, file.length >= targetFrames {
            return finish()
        }
        return nil
    }

    func finish() -> URL? {
        guard let url = fileURL else { return nil }
        file = nil
        fileURL = nil

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 44 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func beginChunk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-copilot-\(UUID().uuidString).wav")
        file = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        fileURL = url
    }
}

private extension CMSampleBuffer {
    var audioPCMBuffer: AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
