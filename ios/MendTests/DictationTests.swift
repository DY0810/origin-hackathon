import Foundation
import Testing
@testable import Mend

struct DictationTests {
    /// Real Whisper tiny.en on a `say`-generated clip. Needs ios/scripts/fetch_whisper.sh (skipped otherwise).
    @Test(.enabled(if: Dictation.isAvailable), .timeLimit(.minutes(3)))
    func transcribesBundledClip() async throws {
        let clip = try #require(Bundle.allBundles.lazy.compactMap { $0.url(forResource: "dictation", withExtension: "wav") }.first)
        let whisper = try await Dictation.load()
        let text = Dictation.text(from: try await whisper.transcribe(audioPath: clip.path, decodeOptions: Dictation.options))
        #expect(text.localizedCaseInsensitiveContains("crack"))
        #expect(text.localizedCaseInsensitiveContains("sidewalk"))
    }

    @Test func draftHintMapsToChipsButNotOther() {
        let draft = ReportNoteDraft(damageTypeHint: "pothole", locationOnAsset: "", mentionsImmediateDanger: false, cleanedNote: "")
        #expect(draft.suggestedType == .pothole)
        #expect(ReportNoteDraft(damageTypeHint: "other", locationOnAsset: "", mentionsImmediateDanger: false, cleanedNote: "").suggestedType == nil)
    }
}
