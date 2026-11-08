import AppKit
import SwiftUI

/// Dictation history: searchable, with the raw transcript one click away.
struct DictationsView: View {
    let model: AppModel
    @State private var query = ""
    @State private var confirmingClear = false

    var body: some View {
        let entries = HistoryEntry.filter(model.history.entries, query: query)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Dictations").font(.system(size: 22, weight: .bold))
                Spacer()
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Clear All…", role: .destructive) { confirmingClear = true }
                    .disabled(model.history.entries.isEmpty)
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 14)

            if model.history.entries.isEmpty {
                ContentUnavailableView {
                    Label("No dictations yet", systemImage: "waveform")
                } description: {
                    Text("Hold \(model.settings.hotkey.label) anywhere to dictate. What you say shows up here.")
                }
                .frame(maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        DictationRow(entry: entry) { model.history.delete(entry.id) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .confirmationDialog("Clear all dictations?", isPresented: $confirmingClear) {
            Button("Clear All", role: .destructive) { model.history.clear() }
        } message: {
            Text("This removes your dictation history from this Mac. It can't be undone.")
        }
    }
}

private struct DictationRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var showingRaw = false

    private var hasDistinctRaw: Bool { entry.text != nil && entry.text != entry.raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: showingRaw ? entry.raw : (entry.text ?? entry.raw))
                .font(.system(size: 14))
                .foregroundStyle(showingRaw ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(entry.date, style: .relative)
                if !entry.app.isEmpty { Text(verbatim: "· \(entry.app)") }
                if let error = entry.error {
                    Text("· not inserted").foregroundStyle(.orange).help(Text(verbatim: error))
                }
                Spacer()
                if hasDistinctRaw {
                    Button(showingRaw ? String(localized: "Show Cleaned") : String(localized: "Show Raw")) {
                        showingRaw.toggle()
                    }
                    .buttonStyle(.link)
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(showingRaw ? entry.raw : (entry.text ?? entry.raw), forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(Text("Copy"))
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(Text("Delete"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text ?? entry.raw, forType: .string)
            }
            if hasDistinctRaw {
                Button("Copy Raw Transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.raw, forType: .string)
                }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
