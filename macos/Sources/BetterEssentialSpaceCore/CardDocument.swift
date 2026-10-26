import Foundation

/// A text edit of one Record. nil field = leave the server's value untouched; ""
/// clears it (summary, topic content). Topics are edited in place, matched by
/// `card_analysis_id` — adding or removing topics is out of scope by decision.
public struct CardTextEdit: Equatable, Sendable, Codable {
    public var title: String?
    public var summary: String?
    public var mainTopics: [MainTopic]?

    public init(title: String? = nil, summary: String? = nil, mainTopics: [MainTopic]? = nil) {
        self.title = title
        self.summary = summary
        self.mainTopics = mainTopics
    }

    /// `newer` layered over this edit: its non-nil fields win, and topics merge
    /// by id so an edit of one topic keeps an earlier edit of another.
    public func merged(with newer: CardTextEdit) -> CardTextEdit {
        var topics = mainTopics ?? []
        for topic in newer.mainTopics ?? [] {
            if let index = topics.firstIndex(where: { $0.id == topic.id }) {
                topics[index] = topic
            } else {
                topics.append(topic)
            }
        }
        return CardTextEdit(
            title: newer.title ?? title,
            summary: newer.summary ?? summary,
            mainTopics: topics.isEmpty ? nil : topics
        )
    }
}

/// The retained `client_request_response` with the one capability that matters:
/// surgical text edits that survive the round trip. JSONSerialization — not
/// Codable — performs the surgery because Codable cannot round-trip unknown
/// keys, and every key this build does not model must come back untouched.
/// The two parsers split the work deliberately: Codable owns the typed
/// projection (`Record.init(card:)`), this type owns mutation of the raw bytes.
public struct CardDocument: Equatable, Sendable {
    public let rawJSON: String

    public init(rawJSON: String) {
        self.rawJSON = rawJSON
    }

    /// The sum of RECORDING metadata `size` values in a raw payload — the honest
    /// per-card size the update envelope encrypts (notes/04: "prefer the sum").
    /// 0 when the payload carries no recording sizes.
    public static func recordingSizeBytes(of rawJSON: String) -> Int64 {
        guard let root = try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any],
              let resources = root["card_resources"] as? [[String: Any]]
        else { return 0 }
        return resources
            .filter { $0["raw_type"] as? String == "RECORDING" }
            .compactMap { resource -> Int64? in
                guard let metadata = resource["metadata"] as? String,
                      let dictionary = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any]
                else { return nil }
                return dictionary["size"] as? Int64
            }
            .reduce(0, +)
    }

    /// Pure. Mutates only `cards.title`, `cards.summary`, and the metadata of
    /// MEETING_MAIN_TOPIC / MEETING_KEY_TOPIC_ANALYSIS `card_analysis` entries
    /// matched by `card_analysis_id`. Every other key — known, unknown, future —
    /// passes through untouched, and a no-op edit returns the exact input bytes.
    /// Throws `ESError.invalidResponse` loudly when the JSON is unparseable or
    /// an edited topic no longer exists (lost race with a reload).
    public func applying(_ edit: CardTextEdit) throws -> CardDocument {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(
                with: Data(rawJSON.utf8),
                options: [.mutableContainers]
            )
        } catch {
            throw ESError.invalidResponse(
                "client_request_response is not parseable JSON: \(error.localizedDescription)"
            )
        }
        guard let root = parsed as? NSMutableDictionary else {
            throw ESError.invalidResponse("client_request_response is not a JSON object")
        }

        var mutated = false
        if let cards = root["cards"] as? NSMutableDictionary {
            if let title = edit.title, Self.normalized(title) != Self.normalized(cards["title"] as? String) {
                cards["title"] = title
                mutated = true
            }
            if let summary = edit.summary, Self.normalized(summary) != Self.normalized(cards["summary"] as? String) {
                cards["summary"] = summary
                mutated = true
            }
        }
        if let topics = edit.mainTopics {
            try applyTopicEdits(topics, to: root, mutated: &mutated)
        }

        guard mutated else { return self }
        let data = try JSONSerialization.data(withJSONObject: root)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ESError.invalidResponse("edited client_request_response is not UTF-8")
        }
        return CardDocument(rawJSON: string)
    }

    /// Every edited topic must resolve to a `card_analysis` entry of a topic raw
    /// type; an id the document no longer carries throws instead of silently
    /// dropping the user's edit.
    private func applyTopicEdits(
        _ topics: [MainTopic],
        to root: NSMutableDictionary,
        mutated: inout Bool
    ) throws {
        guard let analysis = root["card_analysis"] as? NSMutableArray else {
            throw ESError.invalidResponse("card_analysis is missing; cannot edit topics")
        }
        for topic in topics {
            let entry = analysis
                .compactMap { $0 as? NSMutableDictionary }
                .first { Self.isTopicEntry($0) && ($0["card_analysis_id"] as? String) == topic.id }
            guard let entry else {
                throw ESError.invalidResponse("topic \(topic.id) has no matching card_analysis entry")
            }

            let current = Self.decodedTopic(entry["metadata"] as? String)
            if Self.normalized(topic.title) == Self.normalized(current.title),
               Self.normalized(topic.content) == Self.normalized(current.content)
            {
                continue // unchanged topics keep their metadata bytes exactly
            }

            entry["metadata"] = try Self.encodedTopicMetadata(
                dictionary: current.dictionary,
                title: topic.title ?? current.title ?? "",
                content: topic.content
            )
            mutated = true
        }
    }

    private static func isTopicEntry(_ entry: NSDictionary) -> Bool {
        switch entry["raw_type"] as? String {
        case CardAnalysis.RawType.meetingMainTopic.rawValue,
             CardAnalysis.RawType.meetingKeyTopicAnalysis.rawValue:
            return true
        default:
            return false
        }
    }

    /// Mirrors `Record.mainTopic(from:)` so the skip-unchanged comparison judges
    /// against exactly what the UI shows.
    private static func decodedTopic(_ metadata: String?) -> (
        title: String?, content: String?, dictionary: NSMutableDictionary?
    ) {
        guard let metadata, !metadata.isEmpty else { return (nil, nil, nil) }
        guard let dictionary = (try? JSONSerialization.jsonObject(
            with: Data(metadata.utf8),
            options: [.mutableContainers]
        )) as? NSMutableDictionary else {
            return (metadata, nil, nil) // plain string: the whole metadata is the title
        }
        let detailedSummary = dictionary["detailed_summary"] as? String
        let content = detailedSummary?.isEmpty == false ? detailedSummary : dictionary["content"] as? String
        return (dictionary["title"] as? String, content, dictionary)
    }

    /// `title` is always written; content goes back to the key that supplied it
    /// (`detailed_summary` if that was the source, else `content` — added when
    /// neither existed). Clearing content blanks every content-bearing key so
    /// the decode-time `detailed_summary ?? content` fallback cannot resurrect
    /// stale text. A plain-string topic stays a plain string unless the edit
    /// introduces content, which upgrades it to the topic-metadata JSON shape.
    private static func encodedTopicMetadata(
        dictionary: NSMutableDictionary?,
        title: String,
        content: String?
    ) throws -> String {
        let object: NSMutableDictionary
        if let dictionary {
            dictionary["title"] = title
            if let content, !content.isEmpty {
                let detailedSummary = dictionary["detailed_summary"] as? String
                dictionary[detailedSummary?.isEmpty == false ? "detailed_summary" : "content"] = content
            } else {
                for key in ["content", "detailed_summary"] where dictionary[key] != nil {
                    dictionary[key] = ""
                }
            }
            object = dictionary
        } else if let content, !content.isEmpty {
            object = NSMutableDictionary(dictionary: ["title": title, "content": content])
        } else {
            return title
        }
        return String(
            data: try JSONSerialization.data(withJSONObject: object),
            encoding: .utf8
        )!
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
