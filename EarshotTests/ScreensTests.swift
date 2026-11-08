import Foundation
import Testing
@testable import Earshot

struct ActionItemsScreenTests {
    private func meeting(_ title: String, day: TimeInterval, notes: String) -> Meeting {
        var meeting = Meeting(title: title, platform: "Zoom", startedAt: Date(timeIntervalSince1970: day * 86_400))
        meeting.endedAt = meeting.startedAt.addingTimeInterval(600)
        meeting.summary = notes
        return meeting
    }

    private var meetings: [Meeting] {
        [
            meeting("Older", day: 1, notes: "# Older\n## Action items\n- [ ] Priya: Book room\n- [x] Me: Send recap"),
            meeting("Newer", day: 2, notes: "# Newer\n## Action items\n- [ ] Me: Update changelog\n- [ ] Ship it\n- [ ] Jonas: Fix test"),
        ]
    }

    @Test func filters() {
        #expect(ActionItemQuery.items(in: meetings, filter: .mine).map(\.text) == ["Update changelog"])
        #expect(ActionItemQuery.items(in: meetings, filter: .everyone).count == 4)
        #expect(ActionItemQuery.items(in: meetings, filter: .done).map(\.text) == ["Send recap"])
    }

    @Test func groupsByMeetingNewestFirst() {
        let meetings = self.meetings
        let items = ActionItemQuery.items(in: meetings, filter: .everyone)
        let groups = ActionItemQuery.groups(items, by: .meeting, meetings: meetings)
        #expect(groups.map(\.title) == ["Newer", "Older"])
        #expect(groups[0].items.map(\.text) == ["Update changelog", "Ship it", "Fix test"])
        #expect(groups[0].meetingID == meetings[1].id)
    }

    @Test func groupsByOwnerMeFirstUnassignedLast() {
        let items = ActionItemQuery.items(in: meetings, filter: .everyone)
        let groups = ActionItemQuery.groups(items, by: .owner, meetings: meetings)
        #expect(groups.map(\.title) == ["Me", "Jonas", "Priya", String(localized: "Unassigned")])
        #expect(groups.allSatisfy { $0.meetingID == nil })
    }
}

struct DictionaryTextTests {
    @Test func parsesAndTrims() {
        #expect(DictionaryText.terms(in: "Grafana\n  Lyft \n\n") == ["Grafana", "Lyft"])
    }

    @Test func addsWithoutDuplicates() {
        #expect(DictionaryText.adding("Lyft", to: "Grafana") == "Grafana\nLyft")
        #expect(DictionaryText.adding("grafana", to: "Grafana") == "Grafana")
        #expect(DictionaryText.adding("   ", to: "Grafana") == "Grafana")
        #expect(DictionaryText.adding(" Earshot ", to: "") == "Earshot")
    }

    @Test func removes() {
        #expect(DictionaryText.removing("Lyft", from: "Grafana\nLyft\nKubernetes") == "Grafana\nKubernetes")
        #expect(DictionaryText.removing("Missing", from: "Grafana") == "Grafana")
    }
}

@MainActor
struct HistoryStoreTests {
    private func store() -> (HistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "earshot-history-\(UUID().uuidString).json")
        return (HistoryStore(url: url), url)
    }

    @Test func deletePersists() {
        let (history, url) = store()
        let a = HistoryEntry(app: "Slack", raw: "one", text: "One.")
        let b = HistoryEntry(app: "Mail", raw: "two", text: "Two.")
        history.add(a)
        history.add(b)
        history.delete(a.id)
        #expect(history.entries.map(\.id) == [b.id])
        #expect(HistoryStore(url: url).entries.map(\.id) == [b.id])
    }

    @Test func clearPersists() {
        let (history, url) = store()
        history.add(HistoryEntry(app: "Slack", raw: "one", text: "One."))
        history.clear()
        #expect(history.entries.isEmpty)
        #expect(HistoryStore(url: url).entries.isEmpty)
    }

    @Test func filtersByTextRawOrApp() {
        let entries = [
            HistoryEntry(app: "Slack", raw: "ship friday", text: "Ship Friday."),
            HistoryEntry(app: "Mail", raw: "um hello dana", text: "Hello Dana."),
        ]
        #expect(HistoryStore.filter(entries, query: "").count == 2)
        #expect(HistoryStore.filter(entries, query: "friday").map(\.app) == ["Slack"])
        #expect(HistoryStore.filter(entries, query: "um hello").map(\.app) == ["Mail"])
        #expect(HistoryStore.filter(entries, query: "mail").map(\.app) == ["Mail"])
    }
}
