import Foundation

/// Which call app a process belongs to. Browsers count only when a window looks like a call.
struct MeetingPlatform: Hashable, Sendable {
    let id: String
    let name: String
    let isBrowser: Bool

    private static let native: [String: (String, String)] = [
        "us.zoom.xos": ("zoom", "Zoom"),
        "com.microsoft.teams": ("teams", "Microsoft Teams"),
        "com.microsoft.teams2": ("teams", "Microsoft Teams"),
        "com.microsoft.teams2.modulehost": ("teams", "Microsoft Teams"),
        "com.apple.facetime": ("facetime", "FaceTime"),
        "com.apple.avconferenced": ("facetime", "FaceTime"),
        "com.cisco.webexmeetingsapp": ("webex", "Webex"),
        "cisco-systems.spark": ("webex", "Webex"),
        "com.tinyspeck.slackmacgap": ("slack", "Slack"),
        "com.tinyspeck.slackmacgap.helper": ("slack", "Slack"),
        "com.hnc.discord": ("discord", "Discord"),
        "com.hnc.discord.helper.renderer": ("discord", "Discord"),
        "net.whatsapp.whatsapp": ("whatsapp", "WhatsApp"),
        "com.gather.gather": ("gather", "Gather"),
        "app.tuple.app": ("tuple", "Tuple"),
        "io.aircall.phone": ("aircall", "Aircall"),
        "com.electron.dialpad": ("dialpad", "Dialpad"),
    ]

    private static let browsers: [String: (String, String)] = [
        "com.google.chrome": ("chrome", "Chrome"),
        "com.google.chrome.helper": ("chrome", "Chrome"),
        "com.apple.safari": ("safari", "Safari"),
        "com.apple.webkit.gpu": ("safari", "Safari"),
        "company.thebrowser.browser": ("arc", "Arc"),
        "company.thebrowser.browser.helper": ("arc", "Arc"),
        "company.thebrowser.dia": ("dia", "Dia"),
        "com.brave.browser": ("brave", "Brave"),
        "com.brave.browser.helper": ("brave", "Brave"),
        "com.microsoft.edgemac": ("edge", "Microsoft Edge"),
        "com.microsoft.edgemac.helper": ("edge", "Microsoft Edge"),
        "org.mozilla.firefox": ("firefox", "Firefox"),
        "com.vivaldi.vivaldi": ("vivaldi", "Vivaldi"),
        "app.zen-browser.zen": ("zen", "Zen"),
    ]

    /// Window titles that mean a browser tab is a call.
    static let browserCallTitles = [
        "Meet –", "Meet -", "meet.google.com", "Zoom Meeting", "Microsoft Teams", "Whereby", "Around",
        "Webex", "Jitsi Meet", "Huddle",
    ]

    static func forBundleID(_ bundleID: String) -> MeetingPlatform? {
        let key = bundleID.lowercased()
        if let (id, name) = native[key] { return MeetingPlatform(id: id, name: name, isBrowser: false) }
        if let (id, name) = browsers[key] { return MeetingPlatform(id: id, name: name, isBrowser: true) }
        return nil
    }

    static func looksLikeCall(windowTitle: String) -> Bool {
        browserCallTitles.contains { windowTitle.localizedCaseInsensitiveContains($0) }
    }
}
