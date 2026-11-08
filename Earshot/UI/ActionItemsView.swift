import SwiftUI

enum ActionItemFilter: String, CaseIterable, Identifiable, Sendable {
    case mine, everyone, done
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mine: String(localized: "Mine")
        case .everyone: String(localized: "Everyone")
        case .done: String(localized: "Done")
        }
    }
}

enum ActionItemGrouping: String, CaseIterable, Identifiable, Sendable {
    case meeting, owner
    var id: String { rawValue }
    var label: String {
        switch self {
        case .meeting: String(localized: "By Meeting")
        case .owner: String(localized: "By Owner")
        }
    }
}

struct ActionItemGroup: Identifiable, Equatable {
    let id: String
    let title: String
    /// Meeting date, when grouped by meeting.
    let date: Date?
    /// Set when grouped by meeting, so the header can open it.
    let meetingID: Meeting.ID?
    let items: [ActionItem]
}

/// Action items across every meeting's notes.
struct ActionItemsView: View {
    let model: AppModel
    @State private var filter: ActionItemFilter = .mine
    @State private var grouping: ActionItemGrouping = .meeting

    var body: some View {
        let meetings = model.meetings.meetings
        let groups = ActionItemQuery.groups(ActionItemQuery.items(in: meetings, filter: filter), by: grouping, meetings: meetings)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Action Items").font(.system(size: 22, weight: .bold))
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(ActionItemFilter.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Group", selection: $grouping) {
                    ForEach(ActionItemGrouping.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 14)

            if groups.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "checklist")
                } description: {
                    Text("Action items from meeting notes show up here.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups) { group in
                            ActionItemGroupView(group: group, grouping: grouping, model: model)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 26)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .mine: String(localized: "Nothing assigned to you")
        case .everyone: String(localized: "No open action items")
        case .done: String(localized: "Nothing done yet")
        }
    }
}

/// Filtering and grouping for the Action Items screen (pure; unit-tested in ScreensTests).
enum ActionItemQuery {
    static func items(in meetings: [Meeting], filter: ActionItemFilter) -> [ActionItem] {
        meetings.flatMap(\.actionItems).filter { item in
            switch filter {
            case .mine: !item.done && item.isMine
            case .everyone: !item.done
            case .done: item.done
            }
        }
    }

    /// Meeting groups follow meeting date, newest first; owner groups put "Me" first, then
    /// names alphabetically, then unassigned.
    static func groups(_ items: [ActionItem], by grouping: ActionItemGrouping, meetings: [Meeting]) -> [ActionItemGroup] {
        switch grouping {
        case .meeting:
            let byMeeting = Dictionary(grouping: items, by: \.meetingID)
            return byMeeting.values
                .compactMap { items -> ActionItemGroup? in
                    guard let first = items.first else { return nil }
                    return ActionItemGroup(
                        id: first.meetingID.uuidString, title: first.meetingTitle, date: first.meetingDate,
                        meetingID: first.meetingID, items: items.sorted { $0.line < $1.line })
                }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .owner:
            let unassigned = String(localized: "Unassigned")
            let byOwner = Dictionary(grouping: items) { $0.owner ?? "" }
            return byOwner
                .map { owner, items in
                    ActionItemGroup(
                        id: "owner-\(owner)", title: owner.isEmpty ? unassigned : owner, date: nil, meetingID: nil,
                        items: items.sorted { ($0.meetingDate, $1.line) > ($1.meetingDate, $0.line) })
                }
                .sorted { a, b in
                    func rank(_ g: ActionItemGroup) -> Int { g.id == "owner-Me" ? 0 : g.id == "owner-" ? 2 : 1 }
                    return rank(a) != rank(b) ? rank(a) < rank(b)
                        : a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
        }
    }
}

private struct ActionItemGroupView: View {
    let group: ActionItemGroup
    let grouping: ActionItemGrouping
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(group.items) { item in
                ActionItemRow(item: item, showMeeting: grouping == .owner, showOwner: grouping == .meeting, model: model)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    @ViewBuilder private var header: some View {
        if let meetingID = group.meetingID {
            Button {
                open(meetingID)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: group.title).font(.callout.weight(.bold)).foregroundStyle(.primary)
                    if let date = group.date {
                        Text(date, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(Text("Open meeting"))
        } else {
            Chip(text: group.title, color: ownerColor(group.title), bold: true)
        }
    }

    private func open(_ id: Meeting.ID) {
        model.navigation.meetingID = id
        model.navigation.section = .meetings
    }

    private func ownerColor(_ name: String) -> Color {
        if name == "Me" { return Theme.me }
        let participants = model.meetings.meetings.first { $0.id == group.items.first?.meetingID }?.participants ?? []
        return group.id == "owner-" ? Theme.unknown : Theme.color(forName: name, participants: participants)
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let showMeeting: Bool
    let showOwner: Bool
    let model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: Binding(get: { item.done }, set: { _ in model.meetings.toggleTask(item) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: item.text))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.text)
                    .font(.system(size: 14))
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if showMeeting {
                    Button {
                        model.navigation.meetingID = item.meetingID
                        model.navigation.section = .meetings
                    } label: {
                        Text(verbatim: "\(item.meetingTitle) · \(item.meetingDate.formatted(.dateTime.month().day()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
            if showOwner, let owner = item.owner {
                Chip(text: owner, color: color(for: owner), bold: true)
            }
        }
    }

    private func color(for owner: String) -> Color {
        let participants = model.meetings.meetings.first { $0.id == item.meetingID }?.participants ?? []
        return Theme.color(forName: owner, participants: participants)
    }
}
