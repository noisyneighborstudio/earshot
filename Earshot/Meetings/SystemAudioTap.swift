import AVFoundation
import CoreAudio
import os

enum SystemAudioTapError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): String(localized: "Couldn't capture call audio (\(step): \(status)).")
        case .unsupportedFormat: String(localized: "Call audio is in an unsupported format.")
        }
    }
}

/// Captures what call apps play (the other participants) with a Core Audio process tap
/// (macOS 14.2+). Taps the given processes, or everything except Earshot when none are given.
/// Tracks the aggregate device's actual nominal sample rate (e.g. 24 kHz on AirPods HFP)
/// and rebuilds if the output device or its sample rate changes mid-call.
final class SystemAudioTap: @unchecked Sendable {
    static let deviceName = "Earshot Call Capture"

    private struct Pipeline {
        let format: AVAudioFormat
        let converter: AVAudioConverter
    }

    private let controlQueue = DispatchQueue(label: "studio.noisyneighbor.earshot.call-audio")
    private let ioQueue = DispatchQueue(label: "studio.noisyneighbor.earshot.call-audio.io", qos: .userInitiated)
    private let lock = NSLock()
    private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "audio")

    private var pipeline: Pipeline?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapDescription = AudioStreamBasicDescription()
    private var currentOutputUID: String?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var started = false
    private var processes: [AudioObjectID] = []
    private var targetFormat: AVAudioFormat?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func start(
        processes: [AudioObjectID], format target: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        try controlQueue.sync {
            self.processes = processes
            self.targetFormat = target
            self.onBuffer = onBuffer
            do {
                try create(processes: processes, target: target, onBuffer: onBuffer)
                installDefaultOutputListener()
                started = true
            } catch {
                teardown()
                self.targetFormat = nil
                self.onBuffer = nil
                throw error
            }
        }
    }

    func stop() {
        controlQueue.sync {
            started = false
            removeDefaultOutputListener()
            teardown()
            targetFormat = nil
            onBuffer = nil
            processes = []
        }
    }

    /// Core Audio process taps report their native format (typically 48 kHz) via
    /// `kAudioTapPropertyFormat`, while the aggregate device delivers audio at its own
    /// `kAudioDevicePropertyNominalSampleRate` (e.g. 24 kHz on Bluetooth HFP headphones).
    static func effectiveStreamDescription(
        tapDescription: AudioStreamBasicDescription,
        nominalSampleRate: Float64
    ) -> AudioStreamBasicDescription {
        var description = tapDescription
        if nominalSampleRate > 0 {
            description.mSampleRate = nominalSampleRate
        }
        return description
    }

    private func create(
        processes: [AudioObjectID], target: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        let description = processes.isEmpty
            ? CATapDescription(__stereoGlobalTapButExcludeProcesses: ownProcessObject().map { [NSNumber(value: $0)] } ?? [])
            : CATapDescription(__stereoMixdownOfProcesses: processes.map { NSNumber(value: $0) })
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription), "read tap format")
        tapDescription = streamDescription

        let outputUID = try defaultOutputUID()
        currentOutputUID = outputUID
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.deviceName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create aggregate device")

        let nominalRate = nominalSampleRate(of: deviceID)
        try installPipeline(nominalSampleRate: nominalRate, target: target)
        installSampleRateListener(on: deviceID)

        // The IO block runs serially on ioQueue and grabs the latest pipeline snapshot under lock.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, ioQueue) { [weak self] _, inputData, _, _, _ in
            guard let self, let current = self.lock.withLock({ self.pipeline }),
                  let input = AVAudioPCMBuffer(pcmFormat: current.format, bufferListNoCopy: inputData, deallocator: nil),
                  let converted = AudioCapture.convert(input, with: current.converter, to: target)
            else { return }
            onBuffer(converted)
        }, "create IO proc")
        try check(AudioDeviceStart(deviceID, procID), "start device")
        log.info("call tap started: \(outputUID, privacy: .public) @ \(nominalRate, privacy: .public) Hz (tap \(streamDescription.mSampleRate, privacy: .public) Hz)")
    }

    private func installPipeline(nominalSampleRate: Float64, target: AVAudioFormat) throws {
        var effective = Self.effectiveStreamDescription(tapDescription: tapDescription, nominalSampleRate: nominalSampleRate)
        guard let inputFormat = AVAudioFormat(streamDescription: &effective),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw SystemAudioTapError.unsupportedFormat }
        lock.withLock { pipeline = Pipeline(format: inputFormat, converter: converter) }
    }

    private func teardown() {
        removeSampleRateListener()
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        lock.withLock { pipeline = nil }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        currentOutputUID = nil
    }

    private func installSampleRateListener(on device: AudioObjectID) {
        removeSampleRateListener()
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleSampleRateChange()
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, controlQueue, listener) == noErr {
            sampleRateListener = listener
        }
    }

    private func removeSampleRateListener() {
        guard let listener = sampleRateListener, deviceID != kAudioObjectUnknown else { return }
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(deviceID, &addr, controlQueue, listener)
        sampleRateListener = nil
    }

    private func installDefaultOutputListener() {
        removeDefaultOutputListener()
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChange()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue, listener
        ) == noErr {
            defaultOutputListener = listener
        }
    }

    private func removeDefaultOutputListener() {
        guard let listener = defaultOutputListener else { return }
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue, listener)
        defaultOutputListener = nil
    }

    private func handleSampleRateChange() {
        guard started, deviceID != kAudioObjectUnknown, let targetFormat else { return }
        let rate = nominalSampleRate(of: deviceID)
        guard rate > 0 else { return }
        do {
            try installPipeline(nominalSampleRate: rate, target: targetFormat)
            log.info("call tap sample rate changed to \(rate, privacy: .public) Hz")
        } catch {
            log.error("call tap sample rate update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleDefaultOutputChange() {
        guard started, let targetFormat, let onBuffer else { return }
        let nextUID = try? defaultOutputUID()
        guard let nextUID, nextUID != currentOutputUID else { return }
        log.info("default output changed to \(nextUID, privacy: .public); restarting call tap")
        teardown()
        do {
            try create(processes: processes, target: targetFormat, onBuffer: onBuffer)
        } catch {
            log.error("call tap restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func nominalSampleRate(of device: AudioObjectID) -> Float64 {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func defaultOutputUID() throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) != noErr || device == kAudioObjectUnknown {
            addr = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            try check(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device), "find output device")
        }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString>.size)
        addr = Self.address(kAudioDevicePropertyDeviceUID)
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "read output device")
        guard let uid else { throw SystemAudioTapError.coreAudio("read output device", -1) }
        return uid.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw SystemAudioTapError.coreAudio(step, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
