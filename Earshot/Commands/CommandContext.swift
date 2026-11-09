import AppKit
import ApplicationServices

/// A menu bar item of the frontmost app, as a path of titles from the menu bar down.
struct MenuItem: Equatable, Sendable {
    let path: [String]
    let enabled: Bool
    var title: String { path.last ?? "" }
    var display: String { path.joined(separator: " › ") }
}

/// What a voice command acts on: the frontmost app, its window's URL, and its menu bar.
/// Captured when command mode starts, while the user's app is still frontmost.
@MainActor
struct CommandContext {
    var appName = ""
    var bundleID = ""
    var url: String?
    var menu: [MenuItem] = []
    /// Parallel to `menu`, for pressing an item.
    fileprivate var elements: [AXUIElement] = []

    static func capture() -> CommandContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return CommandContext() }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var context = CommandContext(appName: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "")
        // Safari (and other document windows) expose the page or file URL here.
        if let window = AX.element(axApp, kAXFocusedWindowAttribute),
           let document = AX.attribute(window, kAXDocumentAttribute) as? String, !document.isEmpty {
            context.url = document
        }
        if let bar = AX.element(axApp, kAXMenuBarAttribute) {
            // The first menu is the Apple menu: system-wide, not the app's.
            for top in AX.children(bar).dropFirst() {
                guard let title = AX.title(top) else { continue }
                for menu in AX.children(top) { context.collect(menu, path: [title], depth: 1) }
            }
        }
        return context
    }

    private static let maxItems = 1000

    private mutating func collect(_ list: AXUIElement, path: [String], depth: Int) {
        guard AX.attribute(list, kAXRoleAttribute) as? String == kAXMenuRole else { return }
        for item in AX.children(list) {
            guard elements.count < Self.maxItems, let title = AX.title(item) else { continue }
            let submenus = AX.children(item)
            if submenus.isEmpty {
                menu.append(MenuItem(path: path + [title], enabled: AX.attribute(item, kAXEnabledAttribute) as? Bool ?? false))
                elements.append(item)
            } else if depth < 3 {
                for submenu in submenus { collect(submenu, path: path + [title], depth: depth + 1) }
            }
        }
    }

    /// Clicks a menu item captured with this context.
    func press(_ item: MenuItem) throws {
        guard let index = menu.firstIndex(of: item) else {
            throw ActionError(String(localized: "\(item.display) isn't in \(appName)'s menus."))
        }
        let result = AXUIElementPerformAction(elements[index], kAXPressAction as CFString)
        guard result == .success else {
            throw ActionError(String(localized: "Couldn't choose \(item.display) (\(result.rawValue))."))
        }
    }
}

/// Small Accessibility API helpers.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Non-empty title; separators and spacers have none.
    static func title(_ element: AXUIElement) -> String? {
        guard let title = attribute(element, kAXTitleAttribute) as? String,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return title
    }
}
