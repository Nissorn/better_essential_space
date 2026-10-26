import AppKit
import BetterEssentialSpaceCore
import SwiftUI
import UniformTypeIdentifiers

/// Record list + detail (NavigationSplitView) in the app's design language:
/// readable type on cards, gradient canvas, accent-marked selection.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selection: Record.ID?
    @State private var selectedCollectionID: String?
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var visibleRecords: [Record] {
        model.visibleRecords(collectionID: selectedCollectionID, searchQuery: searchQuery)
    }

    private var selectedRecord: Record? {
        guard let id = selection else { return nil }
        return model.records.first { $0.id == id }
    }

    private var hasActiveSearch: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                searchBar
                if !model.collections.isEmpty {
                    collectionsBar
                }
                List(visibleRecords, selection: $selection) { record in
                    RecordRow(record: record, isSelected: selection == record.id)
                        .tag(record.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                .overlay {
                    if visibleRecords.isEmpty {
                        ContentUnavailableView(
                            emptyStateTitle,
                            systemImage: hasActiveSearch ? "magnifyingglass" : "waveform",
                            description: Text(emptyStateDescription)
                        )
                    }
                }
            }
            .navigationTitle("Records")
            .onAppear { listFocused = true }
            .onChange(of: selectedCollectionID) { clearHiddenSelection() }
            .onChange(of: searchQuery) { clearHiddenSelection() }
            .toolbar {
                ToolbarButton(title: "Reload", systemImage: "arrow.clockwise") {
                    model.reload()
                }
                ToolbarButton(title: "Settings", systemImage: "gear") {
                    openSettings()
                }
            }
        } detail: {
            Group {
                if let record = model.records.first(where: { $0.id == selection }) {
                    RecordDetail(record: record, collectionNames: model.collectionNames(for: record))
                } else {
                    ContentUnavailableView(
                        "Select a Record",
                        systemImage: "waveform",
                        description: Text("Pick a Record to read its Transcript.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Better Essential Space")
        .navigationSplitViewStyle(.balanced)
        .appCanvas()
        .focusedSceneValue(
            \.recordCommands,
            RecordCommands(
                focusSearch: { searchFocused = true },
                exportAll: model.records.isEmpty ? nil : { exportAllRecords() },
                exportSelected: selectedRecord == nil ? nil : { exportSelectedRecord() }
            )
        )
    }

    /// The phone app's COLLECTIONS section, adapted to a horizontal chip bar:
    /// "All Records" plus one chip per Collection with its Record count.
    private var collectionsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COLLECTIONS")
                .font(ND.mono(12, weight: .medium))
                .foregroundStyle(ND.textTertiary)
                .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CollectionChip(
                        title: "All Records",
                        count: model.records.count,
                        isSelected: selectedCollectionID == nil
                    ) { selectedCollectionID = nil }
                    ForEach(model.collections, id: \.collectionId) { collection in
                        CollectionChip(
                            title: collection.name ?? "Untitled Collection",
                            count: model.recordCount(in: collection),
                            isSelected: selectedCollectionID == collection.collectionId
                        ) { selectedCollectionID = collection.collectionId }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Client-side search over every user-visible text field (Record.matches):
    /// title, summary, Transcript, topics, speakers.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(ND.mono(12))
                .foregroundStyle(ND.textTertiary)
            TextField("Search Records", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(ND.ui(14))
                .focused($searchFocused)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(ND.textTertiary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ND.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(ND.surfaceBorder, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onExitCommand {
            if !searchQuery.isEmpty { searchQuery = "" }
            listFocused = true
        }
    }

    private var emptyStateTitle: String {
        if hasActiveSearch { return "No Results" }
        return selectedCollectionID == nil ? "No Records" : "Empty Collection"
    }

    private var emptyStateDescription: String {
        if hasActiveSearch {
            return "No Records match “\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))”."
        }
        if selectedCollectionID == nil {
            return "Records appear here once the account's Essential Space has synced voice captures."
        }
        return "This Collection has no Records."
    }

    /// A Record hidden by the current Collection filter or search must not stay
    /// selected in the detail column.
    private func clearHiddenSelection() {
        if let id = selection, !visibleRecords.contains(where: { $0.id == id }) {
            selection = nil
        }
    }

    // MARK: Export (File menu + detail copy)

    private func exportAllRecords() {
        runSavePanel(
            defaultName: "Essential Space Records.md",
            content: RecordMarkdown.combined(records: model.records, collections: model.collections)
        )
    }

    private func exportSelectedRecord() {
        guard let record = selectedRecord else { return }
        runSavePanel(
            defaultName: RecordMarkdown.fileName(for: record),
            content: RecordMarkdown.document(for: record, collectionNames: model.collectionNames(for: record))
        )
    }

    private func runSavePanel(defaultName: String, content: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.show(error: error)
        }
    }
}

/// One sidebar Collection chip: gradient fill + white label when selected,
/// surface + hairline border when not.
private struct CollectionChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(ND.ui(13, weight: .semibold))
                Text("\(count)")
                    .font(ND.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : ND.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : ND.textPrimary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(ND.accentGradient)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(ND.surface)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : ND.surfaceBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ToolbarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .help(title)
    }
}

struct RecordRow: View {
    let record: Record
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(ND.ui(14, weight: isSelected ? .semibold : .medium))
                .lineLimit(2)
                .foregroundStyle(ND.textPrimary)
            HStack(spacing: 10) {
                if let duration = record.audioDurationMS {
                    Text(Duration.milliseconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                }
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().year())
                if record.transcript == nil {
                    Text("no transcript")
                }
            }
            .font(ND.mono(12))
            .foregroundStyle(isSelected ? ND.textSecondary : ND.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? ND.selectionFill : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(ND.accentGradient)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A Record's page. The title, summary, and each main topic edit in place
/// (InlineTextField); Transcript, speakers, and tone stay read-only.
struct RecordDetail: View {
    let record: Record
    var collectionNames: [String] = []

    @Environment(AppModel.self) private var model
    @State private var transcriptExpanded = false
    @FocusState private var focus: EditableField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if record.audioFile != nil {
                    card("Audio") {
                        AudioCardView(record: record, library: model.audio)
                    }
                }

                if !record.mainTopics.isEmpty {
                    card("Main topic") {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.mainTopicsText, forType: .string)
                        } label: {
                            Label("Copy all topics", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(record.mainTopics.enumerated()), id: \.element.id) { index, topic in
                                topicBlock(topic, number: index + 1)
                            }
                        }
                        .padding(.top, 16)
                    }
                }

                if !record.speakers.isEmpty {
                    card("Speakers") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(record.speakers.enumerated()), id: \.offset) { _, speaker in
                                Text("\(speaker.speakerId ?? "Speaker") — \(speaker.description ?? "")")
                                    .font(ND.ui(14))
                                    .foregroundStyle(ND.textSecondary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 14)
                    }
                }

                card("Summary") {
                    InlineTextField(
                        value: record.summary ?? "",
                        placeholder: "Add a summary…",
                        font: ND.body,
                        lineSpacing: 6,
                        field: .summary,
                        focus: $focus
                    ) { model.save(CardTextEdit(summary: $0), recordID: record.id) }
                    .padding(.top, 14)
                }

                card("Transcript") {
                    if let transcript = record.transcript {
                        HStack(spacing: 12) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(transcript, forType: .string)
                            } label: {
                                Label("Copy transcript", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    RecordMarkdown.document(for: record, collectionNames: collectionNames),
                                    forType: .string
                                )
                            } label: {
                                Label("Copy as Markdown", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        DisclosureGroup(isExpanded: $transcriptExpanded) {
                            Text(transcript)
                                .font(ND.body)
                                .foregroundStyle(ND.textPrimary)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 14)
                        } label: {
                            Text(transcriptExpanded ? "Hide transcript" : "Show transcript")
                                .font(ND.ui(14, weight: .medium))
                                .foregroundStyle(ND.accent)
                        }
                        .padding(.top, 14)
                    } else {
                        Text("This Record has no Transcript yet.")
                            .font(ND.ui(14))
                            .foregroundStyle(ND.textTertiary)
                            .padding(.top, 14)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            // Fresh fields per Record: a field's blur commit must never land
            // on the Record selected next.
            .id(record.id)
        }
        .scrollContentBackground(.hidden)
    }

    private func topicBlock(_ topic: MainTopic, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(ND.mono(13, weight: .medium))
                    .foregroundStyle(ND.accent)
                InlineTextField(
                    value: topic.title,
                    placeholder: "Topic",
                    font: ND.ui(15, weight: .semibold),
                    field: .topicTitle(topic.id),
                    focus: $focus,
                    submitFocus: .topicContent(topic.id)
                ) { saveTopic(topic.id, title: $0) }
            }
            InlineTextField(
                value: topic.content ?? "",
                placeholder: "Add details…",
                font: ND.body,
                color: ND.textSecondary,
                lineSpacing: 5,
                field: .topicContent(topic.id),
                focus: $focus
            ) { saveTopic(topic.id, content: $0) }
            .padding(.leading, 25)
        }
    }

    /// A topic edit carries both fields, so the untouched one is read from the
    /// model at commit time rather than from this render.
    private func saveTopic(_ id: String, title: String? = nil, content: String? = nil) {
        guard let current = model.records.first(where: { $0.id == record.id })?
            .mainTopics.first(where: { $0.id == id })
        else { return }
        let topic = MainTopic(id: id, title: title ?? current.title, content: content ?? current.content)
        model.save(CardTextEdit(mainTopics: [topic]), recordID: record.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineTextField(
                value: record.isUntitled ? "" : record.title,
                placeholder: "Untitled",
                font: ND.title,
                field: .title,
                focus: $focus,
                submitFocus: .summary
            ) { model.save(CardTextEdit(title: $0), recordID: record.id) }
            HStack(spacing: 18) {
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                if let duration = record.audioDurationMS {
                    Label(
                        Duration.milliseconds(duration).formatted(.time(pattern: .hourMinuteSecond)),
                        systemImage: "waveform"
                    )
                }
                if let size = record.audioSizeBytes {
                    Label(size.formatted(.byteCount(style: .file)), systemImage: "doc")
                }
                Spacer(minLength: 12)
                EditSyncStatus(recordID: record.id)
            }
            .font(ND.mono(12))
            .foregroundStyle(ND.textTertiary)
            if !collectionNames.isEmpty {
                Text(collectionNames.joined(separator: "  ·  "))
                    .font(ND.mono(12))
                    .foregroundStyle(ND.textSecondary)
            }
            if let mood = record.emotionalSummary, !mood.isEmpty {
                Text(mood)
                    .font(ND.ui(14))
                    .italic()
                    .foregroundStyle(ND.textSecondary)
            }
        }
        .padding(.bottom, 6)
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title)
            content()
        }
        .card()
    }
}

/// Autosave status of one Record (issue 10): "Saving…" while a push is in
/// flight, "Saved" once one lands, or the failure with Retry, the only
/// recovery path.
private struct EditSyncStatus: View {
    let recordID: Record.ID

    @Environment(AppModel.self) private var model
    @State private var hasSaved = false

    var body: some View {
        let state = model.editSyncState(for: recordID)
        Group {
            switch state {
            case .idle:
                if hasSaved {
                    Label("Saved", systemImage: "checkmark")
                }
            case .pushing:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Saving…")
                }
            case .failed(let message):
                HStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(ND.error)
                        .help(message)
                    Button("Retry") {
                        model.retryEditPush(for: recordID)
                    }
                    .buttonStyle(.plain)
                    .font(ND.mono(12, weight: .medium))
                    .foregroundStyle(ND.accent)
                }
            }
        }
        .onChange(of: state) { old, new in
            if old == .pushing, new == .idle { hasSaved = true }
        }
    }
}
