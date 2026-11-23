import AudioToolbox
import AVFoundation
import CoreAudio
import os

enum AudioCaptureError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        String(localized: "No microphone is available.")
    }
}

/// Captures the active microphone (following whichever mic a call app is using and avoiding
/// a closed-lid built-in mic), converts it to `format`, and delivers buffers plus a 0...1 level.
/// When another app turns on voice processing (Safari's calls do), the input stops delivering
/// buffers without any error, so a watchdog rebuilds the engine once buffers stop arriving.
final class AudioCapture: @unchecked Sendable {
    private static let stallLimit: Duration = .seconds(2)

    /// Engine and Core Audio state is touched only on this queue.
    private let queue = DispatchQueue(label: "studio.noisyneighbor.earshot.mic")
    private var engine: AVAudioEngine?
    private var watchdog: DispatchSourceTimer?
    private var currentDevice: AudioInputDevice?
    private var knownRunning: Set<AudioDeviceID> = []
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()
    private var lastBuffer = ContinuousClock.now
    private var lastNonZeroBuffer = ContinuousClock.now
    private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "audio")

    func start(
        format: AVAudioFormat,
        preferRunning: Bool = true,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void
    ) throws {
        try queue.sync {
            let devices = AudioInputs.all()
            let closed = AudioInputs.isClamshellClosed()
            let selected = AudioInputs.preferred(from: devices, preferRunning: preferRunning, clamshellClosed: closed)
            knownRunning = Set(devices.filter(\.isRunningSomewhere).map(\.id))
            try run(format: format, device: selected, onBuffer: onBuffer)

            installDefaultInputListener(format: format, preferRunning: preferRunning, onBuffer: onBuffer)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                self?.checkHealth(format: format, preferRunning: preferRunning, onBuffer: onBuffer)
            }
            timer.resume()
            watchdog = timer
        }
    }

    func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            removeDefaultInputListener()
            teardown()
            currentDevice = nil
            knownRunning = []
        }
    }

    private func checkHealth(
        format: AVAudioFormat,
        preferRunning: Bool,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void
    ) {
        guard engine != nil else { return }
        let (stalled, silent) = lock.withLock {
            let now = ContinuousClock.now
            return (lastBuffer.duration(to: now) > Self.stallLimit,
                    lastNonZeroBuffer.duration(to: now) > Self.stallLimit)
        }
        let devices = AudioInputs.all()
        let closed = AudioInputs.isClamshellClosed()
        let next = AudioInputs.preferred(
            from: devices,
            preferRunning: preferRunning,
            clamshellClosed: closed,
            currentDeviceID: stalled ? nil : currentDevice?.id,
            currentIsSilent: silent,
            knownRunning: knownRunning
        )
        knownRunning = Set(devices.filter(\.isRunningSomewhere).map(\.id))

        if stalled {
            log.error("mic stopped delivering audio; restarting on \(next?.name ?? "default", privacy: .public)")
            restart(format: format, device: next, onBuffer: onBuffer)
        } else if let next, next.id != currentDevice?.id {
            log.info("switching mic from \(self.currentDevice?.name ?? "default", privacy: .public) to \(next.name, privacy: .public)")
            restart(format: format, device: next, onBuffer: onBuffer)
        }
    }

    private func handleDefaultInputChange(
        format: AVAudioFormat,
        preferRunning: Bool,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void
    ) {
        guard engine != nil else { return }
        let devices = AudioInputs.all()
        let closed = AudioInputs.isClamshellClosed()
        knownRunning = Set(devices.filter(\.isRunningSomewhere).map(\.id))
        if let chosen = devices.first(where: \.isDefault),
           !(closed && chosen.isBuiltIn),
           chosen.id != currentDevice?.id {
            log.info("default mic changed to \(chosen.name, privacy: .public); switching")
            restart(format: format, device: chosen, onBuffer: onBuffer)
        } else if let current = currentDevice, !devices.contains(where: { $0.id == current.id }) {
            let next = AudioInputs.preferred(from: devices, preferRunning: preferRunning, clamshellClosed: closed)
            log.info("current mic disconnected; switching to \(next?.name ?? "default", privacy: .public)")
            restart(format: format, device: next, onBuffer: onBuffer)
        }
    }

    private func restart(
        format: AVAudioFormat,
        device: AudioInputDevice?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void
    ) {
        do {
            try run(format: format, device: device, onBuffer: onBuffer)
        } catch {
            log.error("mic restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A fresh engine each time: one that lost its input doesn't recover.
    private func run(
        format: AVAudioFormat,
        device: AudioInputDevice?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void
    ) throws {
        teardown()
        let now = ContinuousClock.now
        lock.withLock {
            lastBuffer = now
            lastNonZeroBuffer = now
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var activeDevice = device
        if let device, !device.isDefault, let audioUnit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                log.error("couldn't select input device \(device.name, privacy: .public) (status \(status)); falling back to default")
                activeDevice = AudioInputs.all().first(where: \.isDefault)
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioCaptureError.noInputDevice
        }
        // Multichannel input (e.g. while voice processing is on) would otherwise map to silence.
        converter.channelMap = [0]

        // The converter is only ever used from the tap's serial audio thread.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [lock = self.lock, weak self] buffer, _ in
            let (level, hasSignal) = Self.measure(buffer)
            lock.withLock {
                let now = ContinuousClock.now
                self?.lastBuffer = now
                if hasSignal { self?.lastNonZeroBuffer = now }
            }
            guard let converted = Self.convert(buffer, with: converter, to: format) else { return }
            onBuffer(converted, level)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.currentDevice = activeDevice
        log.info("mic started: \(activeDevice?.name ?? "default", privacy: .public) (id=\(activeDevice?.id ?? 0))")
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func installDefaultInputListener(
        format: AVAudioFormat,
        preferRunning: Bool,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void
    ) {
        removeDefaultInputListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputChange(format: format, preferRunning: preferRunning, onBuffer: onBuffer)
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        ) == noErr {
            defaultInputListener = listener
        }
    }

    private func removeDefaultInputListener() {
        guard let listener = defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        defaultInputListener = nil
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

    /// RMS level (0...1) and whether the buffer contained any non-zero sample (a hardware-muted
    /// or closed-lid built-in mic delivers exact 0.0 samples, whereas a live mic always has noise floor).
    static func measure(_ buffer: AVAudioPCMBuffer) -> (level: Float, hasSignal: Bool) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return (0, false) }
        let count = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for i in 0..<count { sumSquares += samples[i] * samples[i] }
        return (min(1, (sumSquares / Float(count)).squareRoot() * 6), sumSquares > 0)
    }
}
