import SwiftUI

/// Edits on the dictionary text (one term per line), which stays the single source of truth.
enum DictionaryText {
    static func terms(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Appends `term` unless it's blank or already present (case-insensitive).
    static func adding(_ term: String, to text: String) -> String {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = terms(in: text)
        guard !term.isEmpty, !existing.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
            return text
        }
        return (existing + [term]).joined(separator: "\n")
    }

    static func removing(_ term: String, from text: String) -> String {
        terms(in: text).filter { $0 != term }.joined(separator: "\n")
    }
}

/// The dictionary: terms that bias recognition and fix spelling, plus learned suggestions.
struct DictionaryView: View {
    let model: AppModel
    @State private var newTerm = ""
    @FocusState private var adding: Bool

    var body: some View {
        let terms = DictionaryText.terms(in: model.settings.dictionaryText)
        let suggestions = model.suggestions.ready
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictionary").font(.system(size: 22, weight: .bold))
                    Text("Names, jargon and product terms. Earshot listens for them and Claude spells them exactly as written here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Suggestions")
                            .font(.caption.weight(.bold)).textCase(.uppercase).kerning(0.6).foregroundStyle(.secondary)
                        ForEach(suggestions) { suggestion in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: suggestion.word).font(.system(size: 14, weight: .semibold))
                                    Text("You corrected dictation to this \(suggestion.count) times.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Dismiss") { model.suggestions.dismiss(suggestion) }
                                    .buttonStyle(.borderless)
                                Button("Add") { model.suggestions.accept(suggestion, into: model.settings) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.separator))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Terms")
                        .font(.caption.weight(.bold)).textCase(.uppercase).kerning(0.6).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Add a word or phrase", text: $newTerm)
                            .textFieldStyle(.roundedBorder)
                            .focused($adding)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if terms.isEmpty {
                        Text("No terms yet.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(terms.enumerated()), id: \.offset) { index, term in
                                if index > 0 { Divider() }
                                HStack {
                                    Text(verbatim: term).font(.system(size: 14)).textSelection(.enabled)
                                    Spacer()
                                    Button("Remove \(term)", systemImage: "minus.circle") { remove(term) }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                        .help(Text("Remove"))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func add() {
        model.settings.dictionaryText = DictionaryText.adding(newTerm, to: model.settings.dictionaryText)
        newTerm = ""
        adding = true
    }

    private func remove(_ term: String) {
        model.settings.dictionaryText = DictionaryText.removing(term, from: model.settings.dictionaryText)
    }
}
