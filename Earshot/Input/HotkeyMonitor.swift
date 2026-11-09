import CoreGraphics
import Foundation
import os

enum HotkeyEvent: Sendable {
    case press(at: ContinuousClock.Instant)
    case release(at: ContinuousClock.Instant)
    /// Another key was pressed while the hotkey was held (e.g. fn+arrow), so it isn't dictation.
    case chord
    /// ⌃ joined the held hotkey: a voice command, not dictation.
    case command
    case escape
}

/// A session-level CGEventTap on its own thread and run loop, so a busy main thread
/// can't make the system disable the tap.
final class HotkeyMonitor: @unchecked Sendable {
    private struct Shared {
        var hotkey: Hotkey
        var swallowEscape = false
    }

    private let shared: OSAllocatedUnfairLock<Shared>
    private let onEvent: @Sendable (HotkeyEvent) -> Void
    private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "hotkey")

    // Touched only on the tap thread.
    private var tap: CFMachPort?
    private var held = false
    private var commandSent = false

    init(hotkey: Hotkey, onEvent: @escaping @Sendable (HotkeyEvent) -> Void) {
        shared = OSAllocatedUnfairLock(initialState: Shared(hotkey: hotkey))
        self.onEvent = onEvent
    }

    var hotkey: Hotkey {
        get { shared.withLock { $0.hotkey } }
        set { shared.withLock { $0.hotkey = newValue } }
    }

    /// While dictating, Escape cancels and is not delivered to the focused app.
    var swallowEscape: Bool {
        get { shared.withLock { $0.swallowEscape } }
        set { shared.withLock { $0.swallowEscape = newValue } }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "studio.noisyneighbor.earshot.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()

        // Tap creation fails until Accessibility is granted; keep trying.
        var created: CFMachPort?
        while created == nil {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue().handle(type, event)
                },
                userInfo: info
            )
            if created == nil {
                log.info("event tap unavailable; waiting for Accessibility permission")
                Thread.sleep(forTimeInterval: 2)
            }
        }
        guard let created else { return }
        tap = created
        log.info("event tap installed")

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.warning("event tap disabled by system; re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let hotkey = self.hotkey
            if event.getIntegerValueField(.keyboardEventKeycode) == hotkey.keyCode {
                let down = event.flags.rawValue & hotkey.deviceFlag != 0
                guard down != held else { return pass }
                held = down
                commandSent = false
                onEvent(down ? .press(at: .now) : .release(at: .now))
            }
            // ⌃ before or after the hotkey, either order.
            if held, !commandSent, event.flags.contains(.maskControl) {
                commandSent = true
                onEvent(.command)
            }

        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53, swallowEscape {
                onEvent(.escape)
                return nil
            }
            if held { onEvent(.chord) }

        default:
            break
        }
        return pass
    }
}
