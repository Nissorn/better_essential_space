import Foundation

/// Renders Records as Markdown — one document per Record, or everything in one
/// file — for Export and Copy-as-Markdown (issue 09).
public enum RecordMarkdown {
    /// One Record as a standalone Markdown document.
    public static func document(for record: Record, collectionNames: [String] = []) -> String {
        var lines: [String] = ["# \(record.title)", ""]
        lines.append("- **Date:** \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
        if let duration = record.audioDurationMS {
            lines.append(
                "- **Duration:** \(Duration.milliseconds(duration).formatted(.time(pattern: .hourMinuteSecond)))"
            )
        }
        if let size = record.audioSizeBytes {
            lines.append("- **Size:** \(size.formatted(.byteCount(style: .file)))")
        }
        if !collectionNames.isEmpty {
            lines.append("- **Collections:** \(collectionNames.joined(separator: ", "))")
        }
        if !record.speakers.isEmpty {
            let speakers = record.speakers
                .map { $0.speakerId ?? "Speaker" }
                .joined(separator: ", ")
            lines.append("- **Speakers:** \(speakers)")
        }
        if let mood = record.emotionalSummary, !mood.isEmpty {
            lines += ["", "> \(mood)"]
        }
        if let summary = record.summary, !summary.isEmpty {
            lines += ["", "## Summary", "", summary]
        }
        if !record.mainTopics.isEmpty {
            lines += ["", "## Main topics"]
            for (index, topic) in record.mainTopics.enumerated() {
                lines += ["", "\(index + 1). **\(topic.title)**"]
                if let content = topic.content, !content.isEmpty {
                    lines += ["", content]
                }
            }
        }
        if let transcript = record.transcript, !transcript.isEmpty {
            lines += ["", "## Transcript", "", transcript]
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Every Record in one document (newest first, as the sidebar shows them),
    /// separated by horizontal rules.
    public static func combined(records: [Record], collections: [CollectionSummary] = []) -> String {
        let documents = records.map { record in
            let names = record.collectionIds.compactMap { id in
                collections.first { $0.collectionId == id }?.name
            }
            return document(for: record, collectionNames: names)
        }
        let body = documents.joined(separator: "\n---\n\n")
        return "# Essential Space Records\n\n" + body + "\n"
    }

    /// A safe default file name for one Record: "2026-10-25 Title.md".
    public static func fileName(for record: Record) -> String {
        let date = record.createdAt.formatted(.iso8601.year().month().day())
        let sanitized = record.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let trimmed = String(sanitized.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(date) \(trimmed.isEmpty ? "Untitled Record" : trimmed).md"
    }
}
