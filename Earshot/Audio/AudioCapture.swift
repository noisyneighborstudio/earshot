import AVFoundation
import os

enum AudioCaptureError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        String(localized: "No microphone is available.")
    }
}

/// Captures the default input, converts it to `format`, and delivers buffers plus a 0...1 level.
/// When another app turns on voice processing (Safari's calls do), the input stops delivering
/// buffers without any error, so a watchdog rebuilds the engine once buffers stop arriving.
final class AudioCapture: @unchecked Sendable {
    private static let stallLimit: Duration = .seconds(2)

    /// Engine work happens only on this queue.
    private let queue = DispatchQueue(label: "studio.noisyneighbor.earshot.mic")
    private var engine: AVAudioEngine?
    private var watchdog: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastBuffer = ContinuousClock.now
    private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "audio")

    func start(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) throws {
        try queue.sync {
            try run(format: format, onBuffer: onBuffer)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.restartIfStalled(format: format, onBuffer: onBuffer) }
            timer.resume()
            watchdog = timer
        }
    }

    func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            teardown()
        }
    }

    private func restartIfStalled(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) {
        let stalled = lock.withLock { lastBuffer.duration(to: .now) } > Self.stallLimit
        guard stalled else { return }
        log.error("mic stopped delivering audio; restarting it")
        do {
            try run(format: format, onBuffer: onBuffer)
        } catch {
            log.error("mic restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A fresh engine each time: one that lost its input doesn't recover.
    private func run(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) throws {
        teardown()
        lock.withLock { lastBuffer = .now }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioCaptureError.noInputDevice
        }
        // Multichannel input (e.g. while voice processing is on) would otherwise map to silence.
        converter.channelMap = [0]

        // The converter is only ever used from the tap's serial audio thread.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [lock = self.lock, weak self] buffer, _ in
            lock.withLock { self?.lastBuffer = .now }
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
        self.engine = engine
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
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
