import AppKit
import ApplicationServices

/// Reads the frontmost app and its focused text field through the Accessibility API.
@MainActor
enum FocusReader {
    static func capture() -> FocusContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return FocusContext() }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        // Electron apps only build their AX tree when asked.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var context = FocusContext(appName: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "")
        if let field = element(axApp, kAXFocusedUIElementAttribute),
           attribute(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
           let value = attribute(field, kAXValueAttribute) as? String {
            let selection = attribute(field, kAXSelectedTextRangeAttribute).flatMap(range)
            context.before = FocusContext.before(value, selection: selection)
        }
        return context
    }

    /// The focused field's whole value (not the text before the cursor `capture` keeps). nil for
    /// password fields or when nothing readable is focused.
    static func focusedText() -> (bundleID: String, text: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let field = element(axApp, kAXFocusedUIElementAttribute),
              attribute(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let value = attribute(field, kAXValueAttribute) as? String
        else { return nil }
        return (app.bundleIdentifier ?? "", value)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func range(_ value: CFTypeRef) -> NSRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
