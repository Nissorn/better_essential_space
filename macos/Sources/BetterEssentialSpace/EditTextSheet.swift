import BetterEssentialSpaceCore
import SwiftUI

/// The sheet's mutable mirror of a MainTopic (the domain type is immutable).
private struct DraftTopic: Identifiable {
    let id: String
    var title: String
    var content: String

    init(_ topic: MainTopic) {
        id = topic.id
        title = topic.title
        content = topic.content ?? ""
    }

    var asMainTopic: MainTopic {
        MainTopic(id: id, title: title, content: content.isEmpty ? nil : content)
    }
}

/// One edit session for a Record (issue 10): title, summary, and each main
/// topic's title + content, saved as ONE push. The sheet owns the draft state
/// and the nil-vs-"" decisions (a field the user never touched is sent as nil,
/// so the server's value stays byte-identical); CardDocument owns the JSON
/// surgery, AppModel owns the optimistic state.
struct EditTextSheet: View {
    let record: Record
    let onSave: (CardTextEdit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftTitle: String
    @State private var draftSummary: String
    @State private var draftTopics: [DraftTopic]

    init(record: Record, onSave: @escaping (CardTextEdit) -> Void) {
        self.record = record
        self.onSave = onSave
        // Untouched drafts compare equal to the current values below, so an
        // unchanged field travels as nil (leave the server's value untouched).
        _draftTitle = State(initialValue: record.title)
        _draftSummary = State(initialValue: record.summary ?? "")
        _draftTopics = State(initialValue: record.mainTopics.map(DraftTopic.init))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Record")
                        .font(ND.title)
                    Text("Changes push to Nothing's cloud; the phone app sees them on its next sync.")
                        .font(ND.mono(12))
                        .foregroundStyle(ND.textTertiary)
                }

                NDField(title: "Title", text: $draftTitle)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Summary")
                        .font(ND.mono(12, weight: .medium))
                        .foregroundStyle(ND.textTertiary)
                    TextEditor(text: $draftSummary)
                        .font(ND.body)
                        .frame(minHeight: 72)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ND.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(ND.surfaceBorder, lineWidth: 1)
                        )
                        .scrollContentBackground(.hidden)
                }

                if !draftTopics.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("MAIN TOPICS")
                            .font(ND.mono(12, weight: .medium))
                            .foregroundStyle(ND.textTertiary)
                        ForEach($draftTopics) { $topic in
                            VStack(alignment: .leading, spacing: 7) {
                                NDField(title: "Topic title", text: $topic.title)
                                TextEditor(text: topicContentBinding($topic))
                                    .font(ND.body)
                                    .frame(minHeight: 60)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ND.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(ND.surfaceBorder, lineWidth: 1)
                                    )
                                    .scrollContentBackground(.hidden)
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Save") {
                        onSave(edit)
                        dismiss()
                    }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 560)
        }
        .scrollContentBackground(.hidden)
        .background(ND.backgroundGradient)
        .onExitCommand { dismiss() }
    }

    private var trimmedTitle: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The edit to push: only fields that differ from what the Record already
    /// shows are included; everything else rides as nil = untouched.
    private var editedTopics: [MainTopic] {
        draftTopics.map(\.asMainTopic)
    }

    private var edit: CardTextEdit {
        CardTextEdit(
            title: draftTitle == record.title ? nil : draftTitle,
            summary: draftSummary == (record.summary ?? "") ? nil : draftSummary,
            mainTopics: editedTopics == record.mainTopics ? nil : editedTopics
        )
    }

    private func topicContentBinding(_ topic: Binding<DraftTopic>) -> Binding<String> {
        Binding(
            get: { topic.wrappedValue.content },
            set: { topic.wrappedValue.content = $0 }
        )
    }
}
