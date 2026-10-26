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
                        .id(record.id)
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

struct RecordDetail: View {
    let record: Record
    var collectionNames: [String] = []

    @Environment(AppModel.self) private var model
    @State private var transcriptExpanded = false
    @State private var showEditSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                editSyncStatus

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
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text("\(index + 1)")
                                            .font(ND.mono(13, weight: .medium))
                                            .foregroundStyle(ND.accent)
                                        Text(topic.title)
                                            .font(ND.ui(15, weight: .semibold))
                                            .foregroundStyle(ND.textPrimary)
                                            .textSelection(.enabled)
                                    }
                                    if let content = topic.content, !content.isEmpty {
                                        Text(content)
                                            .font(ND.body)
                                            .foregroundStyle(ND.textSecondary)
                                            .lineSpacing(5)
                                            .textSelection(.enabled)
                                            .padding(.leading, 25)
                                    }
                                }
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

                if let summary = record.summary, !summary.isEmpty {
                    card("Summary") {
                        Text(summary)
                            .font(ND.body)
                            .foregroundStyle(ND.textPrimary)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .padding(.top, 14)
                    }
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
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarButton(title: "Edit", systemImage: "pencil") {
                showEditSheet = true
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditTextSheet(record: record) { edit in
                model.save(edit, for: record)
            }
        }
    }

    /// Push status of the optimistic edit (issue 10): quiet while syncing, a
    /// retryable message when the push failed. Retry is the only recovery path.
    @ViewBuilder
    private var editSyncStatus: some View {
        switch model.editSyncState(for: record.id) {
        case .idle:
            EmptyView()
        case .pushing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving edits…")
                    .font(ND.mono(12))
                    .foregroundStyle(ND.textTertiary)
            }
        case .failed(let message):
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(ND.ui(13))
                    .foregroundStyle(ND.error)
                Button("Retry") {
                    model.retryEditPush(for: record.id)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.title)
                .font(ND.title)
                .foregroundStyle(ND.textPrimary)
                .textSelection(.enabled)
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
