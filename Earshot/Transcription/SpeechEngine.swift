import AVFoundation
import os
import Speech

/// Owns the on-device speech model: resolves the locale, downloads the model if needed,
/// and hands out per-dictation sessions once ready.
@MainActor
@Observable
final class SpeechEngine {
    enum Status: Equatable {
        case preparing
        case downloading(Double)
        case ready
        case unsupported
        case failed(String)
    }

    private(set) var status: Status = .preparing {
        didSet {
            if case .downloading = status, case .downloading = oldValue { return }
            log.info("speech model: \(String(describing: self.status), privacy: .public)")
        }
    }
    private(set) var supportedLocales: [Locale] = []

    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "speech")

    @ObservationIgnored private var locale: Locale?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var preparation: Task<Void, Never>?

    enum Purpose: Sendable {
        /// Short utterances; finals at the end are fine.
        case dictation
        /// Long, continuous speech: finalize as it goes so lines appear (and save) live.
        case meeting
    }

    nonisolated static func module(for locale: Locale, purpose: Purpose = .dictation) -> DictationTranscriber {
        switch purpose {
        case .dictation:
            DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        case .meeting:
            DictationTranscriber(
                locale: locale, contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [])
        }
    }

    func prepare(localeIdentifier: String) {
        preparation?.cancel()
        status = .preparing
        locale = nil
        format = nil
        preparation = Task {
            do {
                if supportedLocales.isEmpty {
                    supportedLocales = await DictationTranscriber.supportedLocales
                        .sorted { $0.identifier < $1.identifier }
                }
                guard let locale = await DictationTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: localeIdentifier))
                else {
                    status = .unsupported
                    return
                }
                let module = Self.module(for: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    status = .downloading(0)
                    let poll = Task {
                        while !Task.isCancelled {
                            status = .downloading(request.progress.fractionCompleted)
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                    defer { poll.cancel() }
                    try await request.downloadAndInstall()
                }
                guard !Task.isCancelled else { return }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    status = .failed(String(localized: "No compatible audio format for the speech model."))
                    return
                }
                self.locale = locale
                self.format = format
                status = .ready
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// nil until the model is ready.
    func makeSession(
        purpose: Purpose = .dictation,
        contextualStrings: [String],
        onTranscript: @escaping @Sendable (TranscriptUpdate) -> Void,
        onSegment: (@Sendable (TranscriptSegment) -> Void)? = nil
    ) -> TranscriptionSession? {
        guard status == .ready, let locale, let format else { return nil }
        return TranscriptionSession(
            locale: locale, purpose: purpose, format: format, contextualStrings: contextualStrings,
            onTranscript: onTranscript, onSegment: onSegment)
    }

    var statusDescription: String {
        switch status {
        case .preparing: String(localized: "Preparing speech model…")
        case .downloading(let fraction): String(localized: "Downloading speech model… \(Int(fraction * 100))%")
        case .ready: String(localized: "Speech model ready")
        case .unsupported: String(localized: "This language isn't supported for on-device dictation.")
        case .failed(let message): String(localized: "Speech model error: \(message)")
        }
    }
}
