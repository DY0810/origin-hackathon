import Foundation
@preconcurrency import WhisperKit

/// Tap-to-talk note dictation, fully on-device: Whisper tiny.en via WhisperKit (open source), bundled by
/// ios/scripts/fetch_whisper.sh. Audio never leaves the phone; only the resulting text goes into the note.
@MainActor @Observable
final class Dictation {
    enum State: Equatable { case idle, loading, recording, transcribing, failed(String) }

    private(set) var state: State = .idle
    private var whisper: WhisperKit?

    nonisolated static let modelFolder = Bundle.main.url(forResource: "Whisper", withExtension: nil)?.appending(path: "openai_whisper-tiny.en")
    nonisolated static var isAvailable: Bool { modelFolder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func start() async {
        guard await AudioProcessor.requestRecordPermission() else {
            state = .failed("Allow microphone access in Settings to dictate.")
            return
        }
        do {
            if whisper == nil {
                state = .loading
                whisper = try await Self.load()
            }
            try whisper?.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
            state = .recording
        } catch {
            state = .failed("Dictation isn't available right now. You can type the note.")
        }
    }

    /// Stops recording and returns the transcript (nil if nothing was heard).
    func stop() async -> String? {
        guard state == .recording, let whisper else { return nil }
        whisper.audioProcessor.stopRecording()
        state = .transcribing
        defer { if state == .transcribing { state = .idle } }
        let samples = Array(whisper.audioProcessor.audioSamples)
        guard let results = try? await whisper.transcribe(audioArray: samples, decodeOptions: Self.options) else {
            state = .failed("Couldn't transcribe that. Try again or type the note.")
            return nil
        }
        let text = Self.text(from: results)
        if text.isEmpty { state = .failed("Didn't catch that. Try again or type the note.") }
        return text.isEmpty ? nil : text
    }

    func cancel() {
        if state == .recording { whisper?.audioProcessor.stopRecording() }
        state = .idle
    }

    nonisolated static let options = DecodingOptions(skipSpecialTokens: true, withoutTimestamps: true)

    nonisolated static func load() async throws -> WhisperKit {
        guard let folder = modelFolder else { throw CocoaError(.fileNoSuchFile) }
        return try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                                     prewarm: false, load: true, download: false))
    }

    /// Joined segment text without Whisper's non-speech markers ("[BLANK_AUDIO]", "(wind blowing)").
    nonisolated static func text(from results: [TranscriptionResult]) -> String {
        results.map(\.text).joined(separator: " ")
            .replacing(/\[[^\]]*\]|\([^)]*\)/, with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
