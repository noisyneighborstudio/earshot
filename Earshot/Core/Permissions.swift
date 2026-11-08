import AppKit
import AVFoundation
import ApplicationServices

@MainActor
@Observable
final class Permissions {
    private(set) var microphone = false
    /// Needed for the event tap (to swallow Escape), reading text fields, and posting ⌘V.
    private(set) var accessibility = false
    private(set) var inputMonitoring = false

    var allGranted: Bool { microphone && accessibility && inputMonitoring }

    @ObservationIgnored private var monitor: Task<Void, Never>?

    func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
    }

    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        }
    }

    func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func requestInputMonitoring() {
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }
}
