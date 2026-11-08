import AVFoundation
import CoreAudio

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
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "studio.noisyneighbor.earshot.call-audio", qos: .userInitiated)

    func start(
        processes: [AudioObjectID], format target: AVAudioFormat,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        do {
            try create(processes: processes, target: target, onBuffer: onBuffer)
        } catch {
            stop()
            throw error
        }
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
        guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription),
              let converter = AVAudioConverter(from: tapFormat, to: target)
        else { throw SystemAudioTapError.unsupportedFormat }

        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earshot Call Capture",
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

        // The converter is only used on our serial IO queue.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, inputData, _, _, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
                  let converted = AudioCapture.convert(input, with: converter, to: target)
            else { return }
            onBuffer(converted)
        }, "create IO proc")
        try check(AudioDeviceStart(deviceID, procID), "start device")
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
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
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
                  "find output device")
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
