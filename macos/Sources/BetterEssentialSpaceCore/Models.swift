import Foundation

// MARK: - Envelope shared by the legacy records host

/// `{code, msg, data}` wrapper every legacy-host response uses. `code == "00000"` means success.
public struct LegacyEnvelope<T: Decodable>: Decodable {
    public let code: String
    public let msg: String?
    public let data: T?
}

// MARK: - Card list (records)

public struct CardListPage: Decodable, Equatable, Sendable {
    public let pageNo: Int
    public let pageSize: Int
    public let hasNextPage: Bool
    public let pageData: [Card]

    public enum CodingKeys: String, CodingKey {
        case pageNo = "page_no"
        case pageSize = "page_size"
        case hasNextPage
        case pageData = "page_data"
    }
}

/// The Card wire model of the legacy storage backend. Records are Cards (GLOSSARY).
/// `clientRequestResponse` is itself a JSON-encoded string — see `CardPayload`.
public struct Card: Decodable, Equatable, Sendable {
    public let cardId: String
    public let clientRequestResponse: String
    public let files: [CardFile]?
    public let clientCreateTime: Int64?
    public let clientUpdateTime: Int64?
    public let clientVersion: Int?

    public enum CodingKeys: String, CodingKey {
        case cardId
        case clientRequestResponse = "client_request_response"
        case files
        case clientCreateTime
        case clientUpdateTime
        case clientVersion
    }
}

public struct CardFile: Decodable, Equatable, Sendable {
    public let region: String?
    public let gcsKey: String?
}

/// One `card_collection_cross_ref` entry: a Collection this Card belongs to.
public struct CardCollectionCrossRef: Decodable, Equatable, Sendable {
    public let collectionId: String?
    public let createTime: Int64?

    enum CodingKeys: String, CodingKey {
        case collectionId = "collection_id"
        case createTime = "create_time"
    }
}

/// Payload decoded from `Card.clientRequestResponse` (the second decode step).
/// Unknown sibling keys are ignored.
public struct CardPayload: Decodable, Equatable, Sendable {
    public let cards: CardInfo
    public let cardResources: [CardResource]
    /// AI analysis of the recording: main topics, emotional summary, … (notes/03).
    public let cardAnalysis: [CardAnalysis]?
    public let meetingSpeakers: [MeetingSpeaker]?
    /// The Collections this Card belongs to (notes/03 § Collections).
    public let cardCollectionCrossRefs: [CardCollectionCrossRef]?

    enum CodingKeys: String, CodingKey {
        case cards
        case cardResources = "card_resources"
        case cardAnalysis = "card_analysis"
        case meetingSpeakers = "meeting_speakers"
        case cardCollectionCrossRefs = "card_collection_cross_ref"
    }
}

/// One `card_analysis` entry. `metadata` is usually a JSON-encoded string
/// (`{"title": …, "content": …}` for main topics) but is a plain string for
/// `MEETING_EMOTIONAL_SUMMARY`.
public struct CardAnalysis: Decodable, Equatable, Sendable {
    public enum RawType: String, Decodable, Sendable {
        case meetingMainTopic = "MEETING_MAIN_TOPIC"
        case meetingKeyTopicAnalysis = "MEETING_KEY_TOPIC_ANALYSIS"
        case meetingEmotionalSummary = "MEETING_EMOTIONAL_SUMMARY"
        case freeform = "FREEFORM"
        /// Lenient fallback: a server-side raw type this build does not know decodes
        /// to `unknown` instead of throwing (which would drop the whole Card).
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Self(rawValue: raw) ?? .unknown
        }
    }

    public let cardAnalysisId: String?
    public let rawType: RawType?
    public let metadata: String?

    enum CodingKeys: String, CodingKey {
        case cardAnalysisId = "card_analysis_id"
        case rawType = "raw_type"
        case metadata
    }
}

public struct MeetingSpeaker: Decodable, Equatable, Sendable {
    public let speakerId: String?
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case description
    }
}

public struct CardInfo: Decodable, Equatable, Sendable {
    public let cardId: String
    public let title: String?
    public let summary: String?
    public let type: String?
    public let createTime: Int64?
    public let updateTime: Int64?
    public let resourceMask: Int?

    public enum CodingKeys: String, CodingKey {
        case cardId = "card_id"
        case title, summary, type
        case createTime = "create_time"
        case updateTime = "update_time"
        case resourceMask = "resource_mask"
    }
}

public struct CardResource: Decodable, Equatable, Sendable {
    public enum RawType: String, Decodable, Sendable {
        case recording = "RECORDING"
        case transcription = "TRANSCRIPTION"
        /// Lenient fallback for future server-side resource kinds (see CardAnalysis.RawType).
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Self(rawValue: raw) ?? .unknown
        }
    }

    public let cardResourceId: String?
    public let rawType: RawType?
    /// For a TRANSCRIPTION resource this holds the full Transcript text inline; empty for RECORDING.
    public let data: String?
    public let mimeType: String?
    public let isPrimary: Bool?
    /// JSON-encoded string on RECORDING resources: size / duration / start_time / end_time. Absent on TRANSCRIPTION.
    public let metadata: String?
    public let createTime: Int64?
    public let updateTime: Int64?
    public let remoteGcsKey: String?
    public let remoteRegion: String?
    public let parentId: String?

    public enum CodingKeys: String, CodingKey {
        case cardResourceId = "card_resource_id"
        case rawType = "raw_type"
        case data
        case mimeType = "mime_type"
        case isPrimary = "is_primary"
        case metadata
        case createTime = "create_time"
        case updateTime = "update_time"
        case remoteGcsKey = "remote_gcsKey"
        case remoteRegion = "remote_region"
        case parentId = "parent_id"
    }
}

/// Decoded from `CardResource.metadata` on RECORDING resources.
public struct RecordingMetadata: Decodable, Equatable, Sendable {
    public let size: Int64?
    public let duration: Int64?
    public let startTime: Int64?
    public let endTime: Int64?

    public enum CodingKeys: String, CodingKey {
        case size, duration
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

/// Request body for `storage/card/v1/list`.
public struct CardListRequest: Encodable, Equatable, Sendable {
    public var pageNo: Int
    public var pageSize: Int
    public var sinceTime: Int64 = 0

    public enum CodingKeys: String, CodingKey {
        case pageNo = "page_no"
        case pageSize = "page_size"
        case sinceTime
    }
}

// MARK: - Categories / Collections

public struct Category: Decodable, Equatable, Sendable {
    public let categoryId: String?
    public let count: Int?

    public enum CodingKeys: String, CodingKey {
        case categoryId
        case count
    }
}

/// Shape of `storage/collection/v1/list` entries, from the live capture (notes/03):
/// `{"collectionId","collectionName","count","clientUpdateTime","clientCreateTime"}`.
/// Every field is optional and unknown keys are ignored so an unexpected schema degrades
/// instead of crashing decoding.
public struct CollectionSummary: Decodable, Equatable, Sendable {
    public let collectionId: String?
    public let name: String?
    public let count: Int?
    /// Server-maintained epochs; used for ordering (the wire sends them per capture).
    public let clientCreateTime: Int64?
    public let clientUpdateTime: Int64?

    public enum CodingKeys: String, CodingKey {
        case collectionId
        case name = "collectionName"
        case count
        case clientCreateTime
        case clientUpdateTime
    }
}

public struct CollectionListRequest: Encodable, Equatable, Sendable {
    public var sinceTime: Int64 = 0

    public enum CodingKeys: String, CodingKey {
        case sinceTime
    }
}

// MARK: - Preferences host

/// `GET /preferences` on `prod.essentialsearch.essential-nt.com`.
public struct Preferences: Decodable, Equatable, Sendable {
    public let userId: String
    public let useMemory: Bool
    public let hasAgreedToTerms: Bool
    public let updatedAt: String
}

// MARK: - Domain model shown in the UI

/// A Record is a voice capture: its title, summary, Transcript, and audio metadata (GLOSSARY).
public struct Record: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let transcript: String?
    public let audioDurationMS: Int64?
    public let audioSizeBytes: Int64?
    public let audioGcsKey: String?
    /// The recording's main topics (the phone app's "Main topic" section).
    public let mainTopics: [MainTopic]
    /// One-line tone summary (`MEETING_EMOTIONAL_SUMMARY`, a plain string).
    public let emotionalSummary: String?
    public let speakers: [MeetingSpeaker]
    /// The Collections this Record belongs to (from the Card's cross-refs).
    public let collectionIds: [String]

    /// All main topics as numbered plain-text blocks ("1. Title\ncontent"), for copying.
    public var mainTopicsText: String {
        mainTopics.enumerated().map { index, topic in
            let heading = "\(index + 1). \(topic.title)"
            if let content = topic.content, !content.isEmpty {
                return heading + "\n" + content
            }
            return heading
        }.joined(separator: "\n\n")
    }

    /// Double-decodes a Card: the outer JSON, then the JSON-encoded `client_request_response`.
    public init(card: Card) throws {
        guard let payloadData = card.clientRequestResponse.data(using: .utf8) else {
            throw ESError.invalidResponse("Card \(card.cardId) has an undecodable client_request_response")
        }
        let payload = try JSONDecoder().decode(CardPayload.self, from: payloadData)

        id = card.cardId
        title = payload.cards.title?.isEmpty == false ? payload.cards.title! : "Untitled Record"
        summary = payload.cards.summary
        createdAt = Date(epochMilliseconds: payload.cards.createTime ?? card.clientCreateTime ?? 0)
        updatedAt = Date(epochMilliseconds: payload.cards.updateTime ?? card.clientUpdateTime ?? 0)

        let transcription = payload.cardResources.first { $0.rawType == .transcription }
        transcript = transcription?.data?.isEmpty == false ? transcription?.data : nil

        let recording = payload.cardResources.first { $0.rawType == .recording }
        if let metadataJSON = recording?.metadata, let metaData = metadataJSON.data(using: .utf8) {
            let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: metaData)
            audioDurationMS = metadata?.duration
            audioSizeBytes = metadata?.size
        } else {
            audioDurationMS = nil
            audioSizeBytes = nil
        }
        audioGcsKey = recording?.remoteGcsKey?.isEmpty == false
            ? recording?.remoteGcsKey
            : card.files?.first?.gcsKey

        var topics: [MainTopic] = []
        var emotional: String?
        for analysis in payload.cardAnalysis ?? [] {
            switch analysis.rawType {
            case .meetingMainTopic, .meetingKeyTopicAnalysis:
                if let topic = Record.mainTopic(from: analysis) { topics.append(topic) }
            case .meetingEmotionalSummary:
                if emotional == nil, let text = analysis.metadata, !text.isEmpty { emotional = text }
            case .freeform, .unknown, nil:
                break
            }
        }
        mainTopics = topics
        emotionalSummary = emotional
        speakers = (payload.meetingSpeakers ?? []).filter { !($0.description ?? "").isEmpty }
        collectionIds = (payload.cardCollectionCrossRefs ?? [])
            .compactMap(\.collectionId)
            .filter { !$0.isEmpty }
    }

    /// `metadata` is `{"title": …, "content": …}` (or `detailed_summary`); a plain
    /// string is tolerated as a topic title with no content.
    private static func mainTopic(from analysis: CardAnalysis) -> MainTopic? {
        struct TopicMetadata: Decodable {
            let title: String?
            let content: String?
            let detailedSummary: String?
            enum CodingKeys: String, CodingKey {
                case title, content
                case detailedSummary = "detailed_summary"
            }
        }
        guard let metadata = analysis.metadata, !metadata.isEmpty else { return nil }
        if let data = metadata.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(TopicMetadata.self, from: data)
        {
            guard let title = parsed.title?.isEmpty == false ? parsed.title : nil else { return nil }
            return MainTopic(
                id: analysis.cardAnalysisId ?? title,
                title: title,
                content: parsed.detailedSummary?.isEmpty == false ? parsed.detailedSummary : parsed.content
            )
        }
        return MainTopic(id: analysis.cardAnalysisId ?? metadata, title: metadata, content: nil)
    }
}

/// One main topic of a Record with its AI-written content.
public struct MainTopic: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let content: String?
}

extension Date {
    public init(epochMilliseconds: Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1000)
    }
}
