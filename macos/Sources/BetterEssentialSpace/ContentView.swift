import AppKit
import BetterEssentialSpaceCore
import SwiftUI

/// Record list + detail (NavigationSplitView, spec's app form).
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Record.ID?

    var body: some View {
        NavigationSplitView {
            List(model.records, selection: $selection) { record in
                RecordRow(record: record)
                    .tag(record.id)
            }
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
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        } detail: {
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
        .navigationTitle("Better Essential Space")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().year())
                if let duration = record.audioDurationMS {
                    Label(
                        Duration.milliseconds(duration).formatted(.time(pattern: .minuteSecond)),
                        systemImage: "waveform"
                    )
                }
                if record.transcript == nil {
                    Text("no transcript")
                        .italic()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct RecordDetail: View {
    let record: Record

    @State private var transcriptExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !record.mainTopics.isEmpty {
                    Section("Main topic") {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.mainTopicsText, forType: .string)
                        } label: {
                            Label("Copy all topics", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(record.mainTopics.enumerated()), id: \.element.id) { index, topic in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(index + 1). \(topic.title)")
                                        .font(.subheadline.weight(.semibold))
                                        .textSelection(.enabled)
                                    if let content = topic.content, !content.isEmpty {
                                        Text(content)
                                            .font(.body)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                if !record.speakers.isEmpty {
                    Section("Speakers") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(record.speakers.enumerated()), id: \.offset) { _, speaker in
                                Text("\(speaker.speakerId ?? "Speaker"): \(speaker.description ?? "")")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let summary = record.summary, !summary.isEmpty {
                    Section("Summary") {
                        Text(summary)
                            .font(.body)
                    }
                }
                Section("Transcript") {
                    if let transcript = record.transcript {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                        } label: {
                            Label("Copy transcript", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        DisclosureGroup(isExpanded: $transcriptExpanded) {
                            Text(transcript)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                        } label: {
                            Text("Show transcript")
                                .font(.subheadline.weight(.semibold))
                        }
                    } else {
                        Text("This Record has no Transcript yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(.title2.bold())
            Text(record.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                .foregroundStyle(.secondary)
            if let duration = record.audioDurationMS {
                Label(
                    Duration.milliseconds(duration).formatted(.time(pattern: .hourMinuteSecond)),
                    systemImage: "waveform"
                )
                .foregroundStyle(.secondary)
            }
            if let size = record.audioSizeBytes {
                Label(size.formatted(.byteCount(style: .file)), systemImage: "doc")
                    .foregroundStyle(.secondary)
            }
            if let mood = record.emotionalSummary, !mood.isEmpty {
                Text(mood)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
