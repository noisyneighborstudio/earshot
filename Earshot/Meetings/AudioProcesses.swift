import CoreAudio
import Foundation

/// A process Core Audio knows about, with its live input/output state (macOS 14.2+).
struct AudioProcess: Sendable, Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

enum AudioProcesses {
    static func all() -> [AudioProcess] {
        let ids: [AudioObjectID] = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return ids.map { id in
            AudioProcess(
                objectID: id,
                pid: scalar(id, kAudioProcessPropertyPID) ?? -1,
                bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: (scalar(id, kAudioProcessPropertyIsRunningInput) as UInt32? ?? 0) != 0,
                isRunningOutput: (scalar(id, kAudioProcessPropertyIsRunningOutput) as UInt32? ?? 0) != 0
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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
