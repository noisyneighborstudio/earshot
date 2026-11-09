import Foundation

enum CommandMatch: Equatable {
    case action(VoiceAction, parameters: [String: String])
    case menu(MenuItem)
    case openApp(name: String, url: URL)
    case openURL(URL)
}

/// Exact matching, in order: actions scoped to this app or page, then the app's own menu items,
/// then global actions, then built-ins ("open Safari", "go to example.com"). Pure, so it's testable.
struct CommandMatcher {
    var actions: [VoiceAction]
    var menu: [MenuItem]
    /// Installed apps by normalized name.
    var apps: [String: URL]
    var bundleID: String
    var url: String?

    func match(_ utterance: String) -> CommandMatch? {
        let text = Phrase.normalize(utterance)
        guard !text.isEmpty else { return nil }
        let applicable = actions.filter { $0.applies(app: bundleID, url: url) }.sorted { $0.specificity > $1.specificity }
        for action in applicable where action.specificity > 0 {
            if let parameters = action.match(text) { return .action(action, parameters: parameters) }
        }
        if let item = menuItem(text) { return .menu(item) }
        for action in applicable where action.specificity == 0 {
            if let parameters = action.match(text) { return .action(action, parameters: parameters) }
        }
        return builtIn(text)
    }

    /// "save", "save this", "add bookmark", or the whole path ("file save").
    private func menuItem(_ text: String) -> MenuItem? {
        let candidates = [text] + Self.objects.compactMap { text.hasSuffix(" " + $0) ? String(text.dropLast($0.count + 1)) : nil }
        let enabled = menu.filter(\.enabled)
        for candidate in candidates {
            if let item = enabled.first(where: { Phrase.normalize($0.title) == candidate }) { return item }
        }
        return enabled.first { Phrase.normalize($0.path.joined(separator: " ")) == text }
    }

    /// Words that point at whatever's in front: "save this", "close it".
    private static let objects = ["this", "it", "that", "this page", "this file", "the page", "the file", "page", "file"]
    private static let openVerbs = ["open", "launch", "start", "switch to", "go to", "show"]

    private func builtIn(_ text: String) -> CommandMatch? {
        for verb in Self.openVerbs where text.hasPrefix(verb + " ") {
            let target = String(text.dropFirst(verb.count + 1))
            if let app = apps[target] { return .openApp(name: target, url: app) }
            if let url = Self.site(target) { return .openURL(url) }
        }
        return nil
    }

    /// "example.com" arrives normalized as "example com"; "dot" may be spoken.
    static func site(_ target: String) -> URL? {
        let words = target.split(separator: " ").map(String.init).filter { $0 != "dot" }
        guard words.count >= 2, let tld = words.last, topLevelDomains.contains(tld) else { return nil }
        return URL(string: "https://" + words.joined(separator: ".").replacingOccurrences(of: "www.", with: ""))
    }

    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "co", "edu", "gov", "me", "us", "uk", "ca", "de", "fr", "studio",
    ]

    /// Installed apps by normalized name, from the standard Applications folders.
    static func installedApps() -> [String: URL] {
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       URL.homeDirectory.appending(path: "Applications").path]
        var apps: [String: URL] = [:]
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                let key = Phrase.normalize(String(name.dropLast(4)))
                if apps[key] == nil { apps[key] = URL(filePath: folder).appending(path: name) }
            }
        }
        return apps
    }
}
