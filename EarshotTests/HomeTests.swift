import Foundation
import Testing
@testable import Earshot

struct HomeLogicTests {
    private func date(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    @Test func greetingByTimeOfDay() {
        #expect(HomeLogic.greeting(for: date(hour: 8)) == "Good morning")
        #expect(HomeLogic.greeting(for: date(hour: 14)) == "Good afternoon")
        #expect(HomeLogic.greeting(for: date(hour: 21)) == "Good evening")
        #expect(HomeLogic.greeting(for: date(hour: 2)) == "Good evening")
    }

    @Test func summaryFirstSentence() {
        let notes = "# Release\n## Summary\nThe team agreed to ship Friday. QA is green.\n## Decisions\n- Ship"
        #expect(HomeLogic.summaryLine(from: notes) == "The team agreed to ship Friday.")
        #expect(HomeLogic.summaryLine(from: "# Title\nJust one line without a period") == "Just one line without a period")
        #expect(HomeLogic.summaryLine(from: "Version 2.4 ships now! Great.") == "Version 2.4 ships now!")
        #expect(HomeLogic.summaryLine(from: nil) == nil)
        #expect(HomeLogic.summaryLine(from: "# Only a title") == nil)
    }

    @Test func openItemsMineFirstThenNewest() {
        var older = Meeting(title: "Older", platform: "", startedAt: Date(timeIntervalSince1970: 0))
        older.summary = "## Action items\n- [ ] Priya: Old task\n- [ ] Me: My old task"
        var newer = Meeting(title: "Newer", platform: "", startedAt: Date(timeIntervalSince1970: 1000))
        newer.summary = "## Action items\n- [ ] Jonas: New task\n- [x] Me: Done task\n- [ ] Unassigned: Loose end"
        let items = HomeLogic.openActionItems([older, newer], limit: 10)
        #expect(items.map(\.text) == ["My old task", "New task", "Loose end", "Old task"])
        #expect(HomeLogic.openActionItems([older, newer], limit: 2).count == 2)
    }

    @Test func firstRunOnlyWhenEmpty() {
        #expect(HomeLogic.isFirstRun(history: [], meetings: []))
        #expect(!HomeLogic.isFirstRun(history: [HistoryEntry(app: "", raw: "hi")], meetings: []))
    }
}
