import AVFoundation

enum AudioCaptureError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        String(localized: "No microphone is available.")
    }
}

/// Captures the default input, converts it to `format`, and delivers buffers plus a 0...1 level.
/// A fresh engine per session avoids stale device configuration after input changes.
final class AudioCapture {
    private let engine = AVAudioEngine()

    func start(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioCaptureError.noInputDevice
        }

        // The converter is only ever used from the tap's serial audio thread.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, with: converter, to: format) else { return }
            onBuffer(converted, Self.level(of: buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// RMS of the first input channel (the input node delivers float samples).
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for i in 0..<count { sumSquares += samples[i] * samples[i] }
        return min(1, (sumSquares / Float(count)).squareRoot() * 6)
    }
}
