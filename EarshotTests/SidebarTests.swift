import Foundation
import Testing
@testable import Earshot

struct MeetingQueryTests {
    private func meeting(_ title: String, starred: Bool = false, folder: String? = nil, notes: String? = "# T",
                         ended: Bool = true, error: String? = nil, text: String = "") -> Meeting {
        var m = Meeting(title: title, platform: "Zoom", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        m.starred = starred
        m.folder = folder
        m.summary = notes
        m.summaryError = error
        m.endedAt = ended ? m.startedAt.addingTimeInterval(600) : nil
        if !text.isEmpty { m.lines = [.init(speaker: .others, start: 0, text: text)] }
        return m
    }

    @Test func filtersByKind() {
        let all = [
            meeting("Starred one", starred: true),
            meeting("In product", folder: "Product"),
            meeting("No notes", notes: nil),
            meeting("Failed", error: "Claude: timed out"),
            meeting("Live", notes: nil, ended: false),
        ]
        #expect(MeetingQuery.apply(all, filter: .starred, query: "").map(\.title) == ["Starred one"])
        #expect(MeetingQuery.apply(all, filter: .folder("Product"), query: "").map(\.title) == ["In product"])
        // A live meeting isn't "needs notes" yet.
        #expect(MeetingQuery.apply(all, filter: .needsNotes, query: "").map(\.title) == ["No notes", "Failed"])
        #expect(MeetingQuery.apply(all, filter: .all, query: "").count == 5)
    }

    @Test func searchesTitleNotesAndTranscript() {
        let all = [
            meeting("Roadmap"),
            meeting("Sync", notes: "# Sync\n## Decisions\n- Ship the **Kestrel** build"),
            meeting("Chat", text: "the budget for kestrel is fine"),
        ]
        #expect(MeetingQuery.apply(all, filter: .all, query: "kestrel").map(\.title) == ["Sync", "Chat"])
        #expect(MeetingQuery.apply(all, filter: .all, query: "  ").count == 3)
        #expect(MeetingQuery.apply(all, filter: .all, query: "ROADMAP").map(\.title) == ["Roadmap"])
    }

    @Test func countsOpenActionItemsAndFolders() {
        let all = [
            meeting("A", folder: "Hiring", notes: "# A\n- [ ] Me: one\n- [x] Me: done\n- [ ] Priya: two"),
            meeting("B", folder: "Hiring"),
        ]
        #expect(MeetingQuery.openActionItems(all) == 2)
        #expect(MeetingQuery.count(all, inFolder: "Hiring") == 2)
        #expect(MeetingQuery.count(all, inFolder: "Product") == 0)
    }

    @Test func breadcrumbAndExportName() {
        #expect(MeetingQuery.breadcrumb(for: meeting("X", folder: "Product")) == "Meetings › Product")
        #expect(MeetingQuery.breadcrumb(for: meeting("X")) == "Meetings")
        let name = MeetingQuery.exportFileName(for: meeting("Q3: plan/review"))
        #expect(name.hasSuffix(" Q3- plan-review.md"))
        #expect(!name.contains("/") && !name.contains(":"))
    }

    @Test func needsNotesFlags() {
        #expect(MeetingRow.flag(for: meeting("ok")) == nil)
        #expect(MeetingRow.flag(for: meeting("x", notes: nil)) == "needs notes")
        #expect(MeetingRow.flag(for: meeting("x", notes: nil,
            error: "Recording was interrupted. The transcript up to that point was saved.")) == "interrupted")
    }
}

@MainActor
struct SidebarSelectionTests {
    @Test func mapsNavigationToRows() {
        let navigation = AppNavigation()
        #expect(SidebarItem.current(navigation) == .section(.home))
        let id = UUID()
        SidebarItem.meeting(id).apply(to: navigation)
        #expect(navigation.section == .meetings && navigation.meetingID == id)
        #expect(SidebarItem.current(navigation) == .meeting(id))

        SidebarItem.folder("Product").apply(to: navigation)
        #expect(navigation.meetingID == nil && navigation.filter == .folder("Product"))
        #expect(SidebarItem.current(navigation) == .folder("Product"))

        // Going to Meetings itself leaves a folder filter, but keeps Starred/Needs Notes.
        SidebarItem.section(.meetings).apply(to: navigation)
        #expect(navigation.filter == .all)
        navigation.filter = .starred
        SidebarItem.section(.meetings).apply(to: navigation)
        #expect(navigation.filter == .starred)
        #expect(SidebarItem.current(navigation) == .section(.meetings))
    }
}
