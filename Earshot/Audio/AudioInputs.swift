import CoreAudio
import Foundation
import IOKit

/// A Core Audio input device currently available on this Mac.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let isRunningSomewhere: Bool
    let isDefault: Bool

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate }
    var isContinuity: Bool {
        transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}

/// Discovers input devices and chooses the right microphone to record from:
/// follows an already-active call microphone (e.g. Zoom using a display or headset mic while
/// macOS's default input is something else) and avoids the built-in laptop mic when the lid is
/// closed (Apple Silicon hardware-mutes it into continuous digital silence).
enum AudioInputs {
    static func all() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let defaultID = defaultDeviceID()
        let ids: [AudioDeviceID] = array(system, kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard hasInputStreams(id),
                  (scalar(id, kAudioDevicePropertyDeviceIsAlive) as UInt32? ?? 0) != 0,
                  (scalar(id, kAudioDevicePropertyIsHidden) as UInt32? ?? 0) == 0,
                  !hasTapList(id)
            else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? ""
            guard name != SystemAudioTap.deviceName else { return nil }
            let transport: UInt32 = scalar(id, kAudioDevicePropertyTransportType) ?? 0
            let isDefault = id == defaultID
            // Private/internal aggregates (Earshot Call Capture, CADefaultDeviceAggregate, screen-capture
            // taps) are still visible to their own process with isHidden == 0; never treat them as mics
            // unless the user explicitly selected a custom Aggregate Device as macOS's default input.
            if transport == kAudioDeviceTransportTypeAggregate && !isDefault { return nil }
            return AudioInputDevice(
                id: id,
                uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                name: name,
                transport: transport,
                isRunningSomewhere: (scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere) as UInt32? ?? 0) != 0,
                isDefault: isDefault
            )
        }
    }

    static func defaultDeviceID() -> AudioDeviceID? {
        guard let id: AudioDeviceID = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// True on a MacBook whose lid is closed (clamshell mode), where macOS hardware-disconnects
    /// the built-in microphone so it delivers only digital silence.
    static func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    /// Picks which input device to capture.
    /// - `preferRunning`: prefer a mic another app is already actively using (e.g. a call app).
    /// - `currentDeviceID`: the device Earshot is already capturing (whose `isRunningSomewhere`
    ///   is therefore true because of us); nil when starting fresh or after a stall.
    /// - `currentIsSilent`: true once the current device has produced exact digital silence
    ///   (all zeros, as from a hardware-muted or closed-lid mic) past the stall limit.
    /// - `knownRunning`: devices already observed as running on the prior check, so two apps
    ///   holding different mics never cause oscillation.
    static func preferred(
        from devices: [AudioInputDevice],
        preferRunning: Bool = true,
        clamshellClosed: Bool,
        currentDeviceID: AudioDeviceID? = nil,
        currentIsSilent: Bool = false,
        knownRunning: Set<AudioDeviceID> = []
    ) -> AudioInputDevice? {
        func isHardwareMuted(_ device: AudioInputDevice) -> Bool {
            clamshellClosed && device.isBuiltIn
        }
        func best(in candidates: [AudioInputDevice]) -> AudioInputDevice? {
            candidates.first(where: \.isDefault)
                ?? candidates.first { !$0.isBuiltIn && !$0.isContinuity }
                ?? candidates.first { !$0.isBuiltIn }
                ?? candidates.first
        }

        if let currentDeviceID, let current = devices.first(where: { $0.id == currentDeviceID }) {
            let otherActive = devices.filter {
                $0.isRunningSomewhere && $0.id != current.id && !isHardwareMuted($0) && !$0.isAggregate
            }
            if isHardwareMuted(current) {
                if preferRunning, let picked = best(in: otherActive) { return picked }
                if let external = devices.first(where: { !$0.isBuiltIn && !$0.isContinuity && !$0.isAggregate }) {
                    return external
                }
                return current
            }
            if currentIsSilent, let picked = best(in: otherActive) {
                return picked
            }
            if preferRunning {
                let newlyActive = otherActive.filter { !knownRunning.contains($0.id) }
                if let picked = best(in: newlyActive) { return picked }
            }
            return current
        }

        if preferRunning {
            let active = devices.filter { $0.isRunningSomewhere && !isHardwareMuted($0) && !$0.isAggregate }
            if let picked = best(in: active) { return picked }
        }
        let defaultDevice = devices.first(where: \.isDefault)
        if let defaultDevice, !isHardwareMuted(defaultDevice) {
            return defaultDevice
        }
        // Never wake an idle Continuity (iPhone) mic unasked — opening it chimes the phone.
        if let external = devices.first(where: { !$0.isBuiltIn && !$0.isContinuity && !$0.isAggregate }) {
            return external
        }
        return defaultDevice ?? devices.first { !$0.isContinuity && !$0.isAggregate } ?? devices.first
    }

    // MARK: - Core Audio helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func hasTapList(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioAggregateDevicePropertyTapList)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var size = UInt32(MemoryLayout<CFArray>.size)
        var value: Unmanaged<CFArray>?
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr,
              let value else { return false }
        return CFArrayGetCount(value.takeRetainedValue()) > 0
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }
}
