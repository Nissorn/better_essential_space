import AppKit
import BetterEssentialSpaceCore
import SwiftUI

/// Record list + detail (NavigationSplitView) in the app's design language:
/// readable type on cards, gradient canvas, accent-marked selection.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selection: Record.ID?

    var body: some View {
        NavigationSplitView {
            List(model.records, selection: $selection) { record in
                RecordRow(record: record, isSelected: selection == record.id)
                    .tag(record.id)
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Records")
            .overlay {
                if model.records.isEmpty {
                    ContentUnavailableView(
                        "No Records",
                        systemImage: "waveform",
                        description: Text("Records appear here once the account's Essential Space has synced voice captures.")
                    )
                }
            }
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
                    RecordDetail(record: record)
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

    @State private var transcriptExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

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
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                        } label: {
                            Label("Copy transcript", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(SecondaryButtonStyle())
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
