import AVFoundation
import Speech

/// A finalized stretch of speech; times are seconds from the session's first audio.
struct TranscriptSegment: Sendable, Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// The running transcript: finalized text plus the still-changing tail.
struct TranscriptUpdate: Sendable, Equatable {
    var finals: String
    var volatile: String

    var display: String { finals + Spacing.join(before: finals, insert: volatile) }
}

struct Transcript: Sendable, Equatable {
    var text: String
    var segments: [TranscriptSegment]
}

/// One on-device transcription. Audio is appended as it arrives (buffered until the
/// analyzer is up); `finish()` flushes and returns the final transcript and its segments.
final class TranscriptionSession: Sendable {
    /// The format `append` expects.
    let format: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let starter: Task<Void, Error>
    private let collector: Task<Transcript, Error>

    /// `onTranscript` gets each running update; `onSegment` each finalized segment.
    init(
        locale: Locale, purpose: SpeechEngine.Purpose, format: AVAudioFormat, contextualStrings: [String],
        onTranscript: @escaping @Sendable (TranscriptUpdate) -> Void,
        onSegment: (@Sendable (TranscriptSegment) -> Void)? = nil
    ) {
        let module = SpeechEngine.module(for: locale, purpose: purpose)
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.format = format
        self.analyzer = analyzer
        self.input = input

        starter = Task {
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: stream)
        }
        collector = Task {
            var finals = ""
            var segments: [TranscriptSegment] = []
            for try await result in module.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finals += Spacing.join(before: finals, insert: text)
                    onTranscript(TranscriptUpdate(finals: finals, volatile: ""))
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Finalization can emit punctuation-only segments; they aren't speech.
                    if trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
                        let segment = TranscriptSegment(
                            start: result.range.start.seconds, end: result.range.end.seconds, text: trimmed)
                        segments.append(segment)
                        onSegment?(segment)
                    }
                } else {
                    onTranscript(TranscriptUpdate(finals: finals, volatile: text))
                }
            }
            return Transcript(text: finals.trimmingCharacters(in: .whitespacesAndNewlines), segments: segments)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> Transcript {
        input.finish()
        return try await withTaskCancellationHandler {
            try await starter.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        input.finish()
        starter.cancel()
        collector.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
