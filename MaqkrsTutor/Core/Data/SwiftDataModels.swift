//
//  SwiftDataModels.swift
//  MaqkrsTutor
//
//  Core/Data — SwiftData persistence layer
//  Architecture: @Planner (Claude Opus 4.6)
//  Implementation: @Coder
//
//  Constraints (from GEMINI.md):
//  - @Model macros exclusively, no CoreData/Realm
//  - Data never leaves the device
//  - JSON assessments require explanation_descriptor on every distractor
//

import Foundation
import SwiftData

// MARK: - Workspaces

/// Top-level container for course-specific study materials, sessions, and artifacts.
@Model
final class CourseWorkspace {
    var id: UUID
    var name: String
    var createdAt: Date
    var lastActivityAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatSession.workspace)
    var sessions: [ChatSession]

    @Relationship(deleteRule: .cascade, inverse: \SourceDocument.workspace)
    var documents: [SourceDocument]

    @Relationship(deleteRule: .cascade, inverse: \StudyArtifact.workspace)
    var artifacts: [StudyArtifact]

    init(
        id: UUID = UUID(),
        name: String = WorkspaceBootstrap.defaultWorkspaceName,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        sessions: [ChatSession] = [],
        documents: [SourceDocument] = [],
        artifacts: [StudyArtifact] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.sessions = sessions
        self.documents = documents
        self.artifacts = artifacts
    }
}

// MARK: - Source Documents

enum SourceDocumentType: String, Codable, CaseIterable, Identifiable {
    case pdf
    case code
    case image
    case audio
    case video
    case text
    case unknown

    nonisolated var id: String { rawValue }

    nonisolated var systemImage: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo.fill"
        case .audio: "waveform"
        case .video: "film.fill"
        case .text: "doc.text.fill"
        case .unknown: "doc.fill"
        }
    }

    nonisolated var isPrimaryStudyDocument: Bool {
        switch self {
        case .pdf, .code, .text:
            return true
        case .image, .audio, .video, .unknown:
            return false
        }
    }
}

enum DocumentReadiness: String, Codable, Sendable {
    case processing
    case directReady
    case indexed
    case indexedAndDirect
    case deferred

    var displayName: String {
        switch self {
        case .processing: "Processing"
        case .directReady: "Direct Ready"
        case .indexed: "Indexed"
        case .indexedAndDirect: "Indexed + Direct"
        case .deferred: "Deferred"
        }
    }

    var systemImage: String {
        switch self {
        case .processing: "hourglass"
        case .directReady: "doc.text"
        case .indexed: "point.3.connected.trianglepath.dotted"
        case .indexedAndDirect: "checkmark.seal"
        case .deferred: "pause.circle"
        }
    }
}

@Model
final class SourceDocument {
    var id: UUID
    var name: String
    var sourceFile: String
    var fileTypeRawValue: String
    var chunkCount: Int
    var ingestedAt: Date
    var lastUsedAt: Date?

    /// Cached text used for direct document prompting without RAG retrieval.
    var directContextText: String?

    /// Whether directContextText was truncated due to on-device limits.
    var directContextTruncated: Bool

    /// Original and processed page counts for PDFs.
    var totalPageCount: Int?
    var processedPageCount: Int?

    var workspace: CourseWorkspace?

    @Relationship(deleteRule: .nullify, inverse: \ChatSession.focusedDocument)
    var focusedInSessions: [ChatSession]

    @Relationship(deleteRule: .nullify, inverse: \StudyArtifact.sourceDocument)
    var artifacts: [StudyArtifact]

    init(
        id: UUID = UUID(),
        name: String,
        sourceFile: String,
        fileType: SourceDocumentType,
        chunkCount: Int,
        ingestedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        directContextText: String? = nil,
        directContextTruncated: Bool = false,
        totalPageCount: Int? = nil,
        processedPageCount: Int? = nil,
        workspace: CourseWorkspace? = nil,
        focusedInSessions: [ChatSession] = [],
        artifacts: [StudyArtifact] = []
    ) {
        self.id = id
        self.name = name
        self.sourceFile = sourceFile
        self.fileTypeRawValue = fileType.rawValue
        self.chunkCount = chunkCount
        self.ingestedAt = ingestedAt
        self.lastUsedAt = lastUsedAt
        self.directContextText = directContextText
        self.directContextTruncated = directContextTruncated
        self.totalPageCount = totalPageCount
        self.processedPageCount = processedPageCount
        self.workspace = workspace
        self.focusedInSessions = focusedInSessions
        self.artifacts = artifacts
    }
}

extension SourceDocument {
    var fileType: SourceDocumentType {
        get { SourceDocumentType(rawValue: fileTypeRawValue) ?? .unknown }
        set { fileTypeRawValue = newValue.rawValue }
    }

    var isPrimaryStudyMaterial: Bool {
        fileType.isPrimaryStudyDocument
    }

    var readiness: DocumentReadiness {
        guard isPrimaryStudyMaterial else { return .deferred }

        let hasDirectContext = !(directContextText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasIndex = chunkCount > 0

        switch (hasDirectContext, hasIndex) {
        case (true, true):
            return .indexedAndDirect
        case (true, false):
            return .directReady
        case (false, true):
            return .indexed
        case (false, false):
            return .processing
        }
    }

    var readinessSubtitle: String {
        var details: [String] = []

        if chunkCount > 0 {
            details.append("\(chunkCount) chunks")
        }

        if let processedPageCount, let totalPageCount {
            if processedPageCount < totalPageCount {
                details.append("\(processedPageCount)/\(totalPageCount) pages loaded")
            } else {
                details.append("\(totalPageCount) pages")
            }
        }

        if directContextTruncated {
            details.append("truncated")
        }

        if details.isEmpty {
            return readiness.displayName
        }

        return details.joined(separator: " · ")
    }
}

// MARK: - Study Modes

enum StudyMode: String, Codable, CaseIterable, Identifiable {
    case tutor
    case summarize
    case translate
    case explain
    case practice

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .tutor: "Tutor"
        case .summarize: "Summarize"
        case .translate: "Translate"
        case .explain: "Explain"
        case .practice: "Practice"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .tutor: "bubble.left.and.text.bubble.right"
        case .summarize: "text.alignleft"
        case .translate: "globe"
        case .explain: "lightbulb"
        case .practice: "checklist"
        }
    }

    nonisolated var requiresFocusedDocument: Bool {
        switch self {
        case .summarize, .translate, .practice:
            true
        case .tutor, .explain:
            false
        }
    }

    nonisolated static func inferred(from prompt: String) -> StudyMode? {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized.contains("summarize") || normalized.contains("summary of this") {
            return .summarize
        }
        if normalized.contains("translate") {
            return .translate
        }
        if normalized.contains("practice question")
            || normalized.contains("quiz me")
            || normalized.contains("flashcard")
            || normalized.contains("quiz card") {
            return .practice
        }
        if normalized.contains("explain") || normalized.contains("walk me through") {
            return .explain
        }

        return nil
    }

    nonisolated static func effective(explicit: StudyMode, prompt: String) -> StudyMode {
        if explicit == .tutor, let inferred = inferred(from: prompt) {
            return inferred
        }
        return explicit
    }
}

// MARK: - Grounding Evidence

struct GroundingEvidence: Codable, Hashable, Sendable, Identifiable {
    let documentID: UUID?
    let sourceFile: String
    let chunkID: UUID?
    let chunkIndex: Int
    let sectionTitle: String?
    let pageLabel: String?
    let score: Float
    let snippet: String

    var id: String {
        if let chunkID {
            return chunkID.uuidString
        }
        return "\(sourceFile)-\(chunkIndex)"
    }
}

// MARK: - Chat Session

/// A single tutoring conversation session.
/// Contains an ordered collection of message turns between the user and the local LLM.
@Model
final class ChatSession {
    /// Unique identifier for the session.
    var id: UUID

    /// User-visible title for the session (auto-generated or user-edited).
    var title: String

    /// Timestamp when the session was created.
    var createdAt: Date

    /// Timestamp of the last message in this session.
    var lastActivityAt: Date

    /// The model identifier used for this session (for example, "gemma4:e4b-it-q4_K_M").
    var modelIdentifier: String

    /// The workspace this session belongs to.
    var workspace: CourseWorkspace?

    /// The document currently in focus for grounded study tasks.
    var focusedDocument: SourceDocument?

    /// Persisted study mode backing store.
    /// Optional to allow lightweight migration from pre-workspace builds.
    var studyModeRawValue: String?

    /// Ordered collection of message turns in this session.
    /// Cascade delete: when a session is deleted, all its turns are deleted.
    @Relationship(deleteRule: .cascade, inverse: \MessageTurn.session)
    var messages: [MessageTurn]

    @Relationship(deleteRule: .nullify, inverse: \StudyArtifact.originatingSession)
    var artifacts: [StudyArtifact]

    init(
        id: UUID = UUID(),
        title: String = "New Session",
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        modelIdentifier: String = "gemma4:e2b-it-q4_K_M",
        workspace: CourseWorkspace? = nil,
        focusedDocument: SourceDocument? = nil,
        studyMode: StudyMode = .tutor,
        messages: [MessageTurn] = [],
        artifacts: [StudyArtifact] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.modelIdentifier = modelIdentifier
        self.workspace = workspace
        self.focusedDocument = focusedDocument
        self.studyModeRawValue = studyMode.rawValue
        self.messages = messages
        self.artifacts = artifacts
    }
}

extension ChatSession {
    var studyMode: StudyMode {
        get { StudyMode(rawValue: studyModeRawValue ?? StudyMode.tutor.rawValue) ?? .tutor }
        set { studyModeRawValue = newValue.rawValue }
    }
}

// MARK: - Message Turn

/// A single message turn within a chat session.
/// Represents either a user prompt or a model response.
@Model
final class MessageTurn {
    /// Unique identifier for the turn.
    var id: UUID

    /// The role of the message author.
    var role: MessageRole

    /// The text content of the message (supports Markdown).
    var content: String

    /// Intermediate reasoning extracted from <think>...</think> tags.
    /// Nil for user messages or models that do not emit reasoning tokens.
    var thoughtProcess: String?

    /// The model identifier that produced this response (e.g., "gemma4:31b").
    /// Nil for user messages.
    var modelIdentifier: String?

    /// Timestamp when this turn was created.
    var timestamp: Date

    /// The ordering index within the parent session.
    var turnIndex: Int

    /// Token count for this message (tracked for context window management).
    var tokenCount: Int

    /// JSON-encoded grounding evidence for this answer.
    /// Nil for user turns or ungrounded model turns.
    var evidenceJSON: String?

    /// JSON-encoded deterministic context snapshot used for this turn.
    /// Optional to allow lightweight migration from older builds.
    var turnContextJSON: String?

    /// Back-reference to the parent session.
    var session: ChatSession?

    init(
        id: UUID = UUID(),
        role: MessageRole = .user,
        content: String = "",
        thoughtProcess: String? = nil,
        modelIdentifier: String? = nil,
        timestamp: Date = Date(),
        turnIndex: Int = 0,
        tokenCount: Int = 0,
        evidenceJSON: String? = nil,
        turnContextJSON: String? = nil,
        session: ChatSession? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thoughtProcess = thoughtProcess
        self.modelIdentifier = modelIdentifier
        self.timestamp = timestamp
        self.turnIndex = turnIndex
        self.tokenCount = tokenCount
        self.evidenceJSON = evidenceJSON
        self.turnContextJSON = turnContextJSON
        self.session = session
    }
}

extension MessageTurn {
    var groundingEvidence: [GroundingEvidence] {
        get {
            guard let evidenceJSON,
                  let data = evidenceJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([GroundingEvidence].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if newValue.isEmpty {
                evidenceJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue),
                      let json = String(data: data, encoding: .utf8) {
                evidenceJSON = json
            }
        }
    }

    var turnContextSnapshot: TurnContextSnapshot? {
        get {
            guard let turnContextJSON,
                  let data = turnContextJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(TurnContextSnapshot.self, from: data) else {
                return nil
            }
            return decoded
        }
        set {
            if let newValue,
               let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                turnContextJSON = json
            } else {
                turnContextJSON = nil
            }
        }
    }
}

// MARK: - Message Role

/// The role of a message author in a conversation turn.
enum MessageRole: String, Codable, CaseIterable {
    case user = "user"
    case model = "model"
    case system = "system"
}

// MARK: - Supported Languages

/// Languages the tutor can respond in.
/// The raw value is displayed in the UI picker; `bcp47Code` is used by AVSpeechSynthesizer.
enum SupportedLanguage: String, CaseIterable, Codable, Identifiable {
    case english  = "English"
    case turkish  = "Turkish"
    case hindi    = "Hindi"
    case swahili  = "Swahili"
    case mandarin = "Mandarin"
    case bengali  = "Bengali"

    var id: String { rawValue }

    /// BCP-47 language tag used by `AVSpeechSynthesisVoice` and system locale.
    var bcp47Code: String {
        switch self {
        case .english:  "en-US"
        case .turkish:  "tr-TR"
        case .hindi:    "hi-IN"
        case .swahili:  "sw-KE"
        case .mandarin: "zh-CN"
        case .bengali:  "bn-BD"
        }
    }

    /// Returns the `SupportedLanguage` matching a raw value string, defaulting to English.
    static func from(rawValue: String) -> SupportedLanguage {
        allCases.first { $0.rawValue == rawValue } ?? .english
    }
}

// MARK: - Study Artifacts

enum StudyArtifactKind: String, Codable, CaseIterable, Identifiable {
    case summary
    case translation
    case practiceSet = "practice_set"
    case quizCardDeck = "quiz_card_deck"

    nonisolated var id: String { rawValue }
}

struct QuizCard: Codable, Hashable, Sendable {
    let front: String
    let back: String
    let explanation: String
    let difficulty: DifficultyTier
    let evidence: [GroundingEvidence]
}

struct QuizCardDeck: Codable, Hashable, Sendable {
    let title: String
    let cards: [QuizCard]
}

@Model
final class StudyArtifact {
    var id: UUID
    var title: String
    var kindRawValue: String
    var content: String
    var createdAt: Date

    var workspace: CourseWorkspace?
    var sourceDocument: SourceDocument?
    var originatingSession: ChatSession?

    init(
        id: UUID = UUID(),
        title: String,
        kind: StudyArtifactKind,
        content: String,
        createdAt: Date = Date(),
        workspace: CourseWorkspace? = nil,
        sourceDocument: SourceDocument? = nil,
        originatingSession: ChatSession? = nil
    ) {
        self.id = id
        self.title = title
        self.kindRawValue = kind.rawValue
        self.content = content
        self.createdAt = createdAt
        self.workspace = workspace
        self.sourceDocument = sourceDocument
        self.originatingSession = originatingSession
    }
}

extension StudyArtifact {
    var kind: StudyArtifactKind {
        get { StudyArtifactKind(rawValue: kindRawValue) ?? .summary }
        set { kindRawValue = newValue.rawValue }
    }
}

// MARK: - Persistence Bootstrap

enum WorkspaceBootstrap {
    static let defaultWorkspaceName = "My Studies"

    @MainActor
    static func ensureDefaultWorkspace(in modelContext: ModelContext) -> CourseWorkspace {
        let workspaceDescriptor = FetchDescriptor<CourseWorkspace>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let existingWorkspaces = (try? modelContext.fetch(workspaceDescriptor)) ?? []
        let workspace = existingWorkspaces.first ?? {
            let created = CourseWorkspace(name: defaultWorkspaceName)
            modelContext.insert(created)
            return created
        }()

        let sessionDescriptor = FetchDescriptor<ChatSession>()
        let existingSessions = (try? modelContext.fetch(sessionDescriptor)) ?? []

        for session in existingSessions where session.studyModeRawValue == nil {
            session.studyModeRawValue = StudyMode.tutor.rawValue
        }

        let orphanSessions = existingSessions.filter { $0.workspace == nil }
        for session in orphanSessions {
            session.workspace = workspace
        }

        return workspace
    }
}

// MARK: - Pedagogical Assessment (Strictly Typed JSON)

/// A strictly typed practice assessment generated by the local LLM.
/// Schema enforcement is non-negotiable — reject malformed LLM responses.
struct PedagogicalAssessment: Codable, Hashable {
    /// The assessment question text.
    let question: String

    /// The subject domain (e.g., "Swift Concurrency", "Linear Algebra").
    let subject: String

    /// Difficulty tier for adaptive learning.
    let difficulty: DifficultyTier

    /// The single correct answer.
    let correctAnswer: AssessmentOption

    /// Incorrect options. Each MUST include an explanation_descriptor
    /// detailing the specific pedagogical fallacy (per GEMINI.md §2).
    let distractors: [Distractor]

    /// Optional explanation shown after the user answers.
    let explanation: String?
}

/// Difficulty tiers for adaptive assessment generation.
enum DifficultyTier: String, Codable, CaseIterable {
    case foundational = "foundational"
    case intermediate = "intermediate"
    case advanced = "advanced"
    case expert = "expert"
}

/// A correct answer option in an assessment.
struct AssessmentOption: Codable, Hashable {
    /// The answer text.
    let text: String

    /// Why this answer is correct (pedagogical reinforcement).
    let reasoning: String
}

/// An incorrect answer option (distractor) with mandatory pedagogical metadata.
/// Per GEMINI.md: Every distractor MUST include an explanation_descriptor.
struct Distractor: Codable, Hashable {
    /// The distractor text (plausible but incorrect).
    let text: String

    /// REQUIRED: The specific pedagogical fallacy this distractor targets.
    /// Examples: "common_misconception", "off_by_one", "type_confusion",
    ///           "scope_error", "precedence_misunderstanding"
    let explanationDescriptor: String

    /// Human-readable explanation of why this answer is wrong.
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case text
        case explanationDescriptor = "explanation_descriptor"
        case explanation
    }
}

// MARK: - Assessment Validation

extension PedagogicalAssessment {
    /// Validates that the assessment conforms to GEMINI.md schema requirements.
    /// Returns nil if valid, or a description of the violation.
    func validate() -> String? {
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Assessment question cannot be empty"
        }
        if distractors.isEmpty {
            return "Assessment must have at least one distractor"
        }
        for (index, distractor) in distractors.enumerated() {
            if distractor.explanationDescriptor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Distractor \(index) missing required explanation_descriptor"
            }
        }
        return nil // Valid
    }
}
