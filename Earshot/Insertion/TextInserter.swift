import AppKit

/// Inserts text by pasting, then restores the user's clipboard.
///
/// The text goes on the pasteboard as a *promise*: the target app has to request the data,
/// which is how we know the paste landed. If nothing requests it, the text stays on the
/// clipboard and the caller tells the user to paste manually.
@MainActor
final class TextInserter: NSObject {
    enum Outcome: Equatable { case pasted, leftOnClipboard }

    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Large payloads we don't copy into memory just to restore them.
    private static let skipped: Set<NSPasteboard.PasteboardType> = [
        .init("NSFileContentsPboardType"), .pdf, .rtfd, .sound,
    ]

    private var pending: String?
    private var requested = false

    func insert(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        pending = text
        requested = false
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        // Clipboard managers that honor this skip the item, so they don't fake a "request".
        item.setData(Data(), forType: Self.transient)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        KeySender.paste()

        let deadline = ContinuousClock.now + .seconds(1)
        while !requested, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard requested else { return .leftOnClipboard }

        try? await Task.sleep(for: .milliseconds(300))
        // Don't clobber something the user copied in the meantime.
        if pasteboard.changeCount == ourChange { Self.restore(saved, to: pasteboard) }
        return .pasted
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where !skipped.contains(type) {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.filter { !$0.isEmpty }.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

extension TextInserter: NSPasteboardItemDataProvider {
    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // AppKit calls providers on the main thread.
        let text = MainActor.assumeIsolated { () -> String? in
            requested = true
            return pending
        }
        if let text { item.setString(text, forType: type) }
    }
}
