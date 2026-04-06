//
//  ChatOrchestrator.swift
//  MaqkrsTutor
//
//  Core/Chat — Deterministic turn resolution and transcript export
//

import Foundation

enum SourceResolutionKind: String, Codable, Sendable {
    case explicitDocument
    case stagedDocument
    case focusedDocument
    case assistantMessage
    case workspaceFallback
    case none
}

struct ResolvedDocumentReference: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let name: String
}

struct SourceManifest: Codable, Hashable, Sendable {
    let kind: SourceResolutionKind
    let documents: [ResolvedDocumentReference]
    let assistantMessageID: UUID?
    let explicitDocumentOverride: Bool

    var primaryDocumentID: UUID? {
        documents.first?.id
    }

    var primaryDocumentName: String? {
        documents.first?.name
    }

    var documentIDs: [UUID] {
        documents.map(\.id)
    }

    var documentNames: [String] {
        documents.map(\.name)
    }

    var sourceSummary: String {
        switch kind {
        case .assistantMessage:
            return "Last assistant response"
        case .workspaceFallback:
            return "Workspace materials"
        case .none:
            return "No resolved source"
        case .explicitDocument, .stagedDocument, .focusedDocument:
            return documentNames.joined(separator: ", ")
        }
    }
}

struct TurnContextSnapshot: Codable, Hashable, Sendable {
    let resolvedModeRawValue: String
    let resolvedLanguage: String
    let focusedDocumentID: UUID?
    let focusedDocumentName: String?
    let sourceKindRawValue: String
    let sourceDocumentIDs: [UUID]
    let sourceDocumentNames: [String]
    let explicitDocumentOverride: Bool
    let explicitLanguageOverride: Bool

    var resolvedMode: StudyMode {
        StudyMode(rawValue: resolvedModeRawValue) ?? .tutor
    }

    var sourceKind: SourceResolutionKind {
        SourceResolutionKind(rawValue: sourceKindRawValue) ?? .none
    }

    var sourceSummary: String {
        switch sourceKind {
        case .assistantMessage:
            return "Last assistant response"
        case .workspaceFallback:
            return "Workspace materials"
        case .none:
            return "No resolved source"
        case .explicitDocument, .stagedDocument, .focusedDocument:
            return sourceDocumentNames.joined(separator: ", ")
        }
    }
}

struct ResolvedTurnRequest: Sendable {
    let prompt: String
    let mode: StudyMode
    let language: String
    let sourceManifest: SourceManifest
    let workspaceID: UUID?
    let directDocumentContext: String?
    let directDocumentContextTruncated: Bool
    let assistantSourceText: String?
    let stagedImages: [String]
    let historyMessages: [OllamaChatMessage]
    let groundingStrategy: GroundingStrategy
    let explicitLanguageOverride: Bool
    let turnContextSnapshot: TurnContextSnapshot
    let guardrailMessage: String?
}

private enum InternalSourceResolution {
    case document(SourceDocument, kind: SourceResolutionKind, explicitOverride: Bool)
    case assistantMessage(MessageTurn)
    case workspaceFallback
    case none
    case guardrail(String)
}

@MainActor
enum ChatOrchestrator {
    static func resolveTurn(
        session: ChatSession,
        currentUserTurn: MessageTurn,
        availableDocuments: [SourceDocument],
        stagedDocuments: [SourceDocument],
        stagedImages: [String],
        selectedLanguage: String
    ) -> ResolvedTurnRequest {
        let prompt = currentUserTurn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMode = resolveMode(prompt: prompt, defaultMode: session.studyMode)
        let languageResolution = resolveLanguage(prompt: prompt, selectedLanguage: selectedLanguage)

        let sourceResolution = resolveSource(
            prompt: prompt,
            session: session,
            availableDocuments: availableDocuments,
            stagedDocuments: stagedDocuments,
            resolvedMode: resolvedMode
        )

        let manifest = sourceManifest(from: sourceResolution)
        let snapshot = TurnContextSnapshot(
            resolvedModeRawValue: resolvedMode.rawValue,
            resolvedLanguage: languageResolution.language,
            focusedDocumentID: session.focusedDocument?.id,
            focusedDocumentName: session.focusedDocument?.name,
            sourceKindRawValue: manifest.kind.rawValue,
            sourceDocumentIDs: manifest.documentIDs,
            sourceDocumentNames: manifest.documentNames,
            explicitDocumentOverride: manifest.explicitDocumentOverride,
            explicitLanguageOverride: languageResolution.explicitOverride
        )

        switch sourceResolution {
        case .guardrail(let message):
            return ResolvedTurnRequest(
                prompt: prompt,
                mode: resolvedMode,
                language: languageResolution.language,
                sourceManifest: manifest,
                workspaceID: session.workspace?.id,
                directDocumentContext: nil,
                directDocumentContextTruncated: false,
                assistantSourceText: nil,
                stagedImages: stagedImages,
                historyMessages: [],
                groundingStrategy: .requiresDocumentSelection(resolvedMode),
                explicitLanguageOverride: languageResolution.explicitOverride,
                turnContextSnapshot: snapshot,
                guardrailMessage: message
            )
        default:
            break
        }

        if case .document(let document, .explicitDocument, _) = sourceResolution,
           session.focusedDocument?.id != document.id {
            session.focusedDocument = document
            document.lastUsedAt = Date()
        }

        let groundingStrategy = groundingStrategy(
            resolvedMode: resolvedMode,
            sourceResolution: sourceResolution,
            workspaceID: session.workspace?.id
        )

        let directDocumentContext: String?
        let directDocumentContextTruncated: Bool
        let assistantSourceText: String?
        switch sourceResolution {
        case .document(let document, _, _):
            directDocumentContext = document.directContextText
            directDocumentContextTruncated = document.directContextTruncated
            assistantSourceText = nil
        case .assistantMessage(let turn):
            directDocumentContext = nil
            directDocumentContextTruncated = false
            assistantSourceText = turn.content
        default:
            directDocumentContext = nil
            directDocumentContextTruncated = false
            assistantSourceText = nil
        }

        let historyMessages = scopedHistoryMessages(
            session: session,
            currentUserTurn: currentUserTurn,
            prompt: prompt,
            resolvedMode: resolvedMode,
            sourceResolution: sourceResolution,
            stagedImages: stagedImages
        )

        return ResolvedTurnRequest(
            prompt: prompt,
            mode: resolvedMode,
            language: languageResolution.language,
            sourceManifest: manifest,
            workspaceID: session.workspace?.id,
            directDocumentContext: directDocumentContext,
            directDocumentContextTruncated: directDocumentContextTruncated,
            assistantSourceText: assistantSourceText,
            stagedImages: stagedImages,
            historyMessages: historyMessages,
            groundingStrategy: groundingStrategy,
            explicitLanguageOverride: languageResolution.explicitOverride,
            turnContextSnapshot: snapshot,
            guardrailMessage: nil
        )
    }

    static func resolveMode(prompt: String, defaultMode: StudyMode) -> StudyMode {
        explicitMode(from: prompt) ?? defaultMode
    }

    static func resolveLanguage(
        prompt: String,
        selectedLanguage: String
    ) -> (language: String, explicitOverride: Bool) {
        let lowercased = prompt.lowercased()

        for language in SupportedLanguage.allCases {
            for alias in language.matchPhrases {
                if lowercased.contains("to \(alias)")
                    || lowercased.contains("into \(alias)")
                    || lowercased.contains("in \(alias)") {
                    return (language.rawValue, true)
                }
            }
        }

        return (selectedLanguage, false)
    }

    private static func resolveSource(
        prompt: String,
        session: ChatSession,
        availableDocuments: [SourceDocument],
        stagedDocuments: [SourceDocument],
        resolvedMode: StudyMode
    ) -> InternalSourceResolution {
        let promptFlags = PromptFlags(prompt: prompt)
        let documents = uniqueDocuments(availableDocuments + stagedDocuments)

        if let explicitDocument = explicitlyNamedDocument(in: prompt, among: documents) {
            return .document(explicitDocument, kind: .explicitDocument, explicitOverride: true)
        }

        if stagedDocuments.count == 1, let stagedDocument = stagedDocuments.first {
            return .document(stagedDocument, kind: .stagedDocument, explicitOverride: false)
        }

        if stagedDocuments.count > 1, promptFlags.referencesDeicticDocument || resolvedMode.requiresFocusedDocument {
            return .guardrail("Choose a single document before asking about \"this\" source.")
        }

        if resolvedMode == .translate, promptFlags.prefersAssistantResponseSource {
            if let assistantTurn = lastAssistantTurn(in: session) {
                return .assistantMessage(assistantTurn)
            }
            return .guardrail("There is no previous assistant response to translate. Choose a document or ask a question first.")
        }

        if let focusedDocument = session.focusedDocument,
           focusedDocument.isPrimaryStudyMaterial {
            return .document(focusedDocument, kind: .focusedDocument, explicitOverride: false)
        }

        if resolvedMode.requiresFocusedDocument {
            return .guardrail("Choose a document before using \(resolvedMode.displayName.lowercased()) mode.")
        }

        if session.workspace != nil {
            return .workspaceFallback
        }

        return .none
    }

    private static func sourceManifest(from resolution: InternalSourceResolution) -> SourceManifest {
        switch resolution {
        case .document(let document, let kind, let explicitOverride):
            return SourceManifest(
                kind: kind,
                documents: [.init(id: document.id, name: document.name)],
                assistantMessageID: nil,
                explicitDocumentOverride: explicitOverride
            )
        case .assistantMessage(let turn):
            return SourceManifest(
                kind: .assistantMessage,
                documents: [],
                assistantMessageID: turn.id,
                explicitDocumentOverride: false
            )
        case .workspaceFallback:
            return SourceManifest(
                kind: .workspaceFallback,
                documents: [],
                assistantMessageID: nil,
                explicitDocumentOverride: false
            )
        case .none, .guardrail:
            return SourceManifest(
                kind: .none,
                documents: [],
                assistantMessageID: nil,
                explicitDocumentOverride: false
            )
        }
    }

    private static func groundingStrategy(
        resolvedMode: StudyMode,
        sourceResolution: InternalSourceResolution,
        workspaceID: UUID?
    ) -> GroundingStrategy {
        switch sourceResolution {
        case .document(let document, _, _):
            if resolvedMode == .summarize {
                return .documentSummary(document.id)
            }
            if let workspaceID {
                return .scopedQuery(.hybrid(documentID: document.id, workspaceID: workspaceID))
            }
            return .scopedQuery(.document(document.id))

        case .assistantMessage:
            return .none

        case .workspaceFallback:
            if let workspaceID {
                return .scopedQuery(.workspace(workspaceID))
            }
            return .none

        case .none:
            return resolvedMode.requiresFocusedDocument
                ? .requiresDocumentSelection(resolvedMode)
                : .none

        case .guardrail:
            return .requiresDocumentSelection(resolvedMode)
        }
    }

    private static func scopedHistoryMessages(
        session: ChatSession,
        currentUserTurn: MessageTurn,
        prompt: String,
        resolvedMode: StudyMode,
        sourceResolution: InternalSourceResolution,
        stagedImages: [String]
    ) -> [OllamaChatMessage] {
        let sortedTurns = session.messages.sorted { $0.turnIndex < $1.turnIndex }

        switch sourceResolution {
        case .assistantMessage(let assistantTurn):
            return [
                .init(role: "assistant", content: assistantTurn.content),
                .init(role: "user", content: prompt, images: stagedImages.isEmpty ? nil : stagedImages)
            ]

        case .document(let document, _, _):
            let primaryDocumentID = document.id
            let sameDocumentTurns = sortedTurns.filter { turn in
                guard turn.id != currentUserTurn.id else { return false }
                return turn.turnContextSnapshot?.sourceDocumentIDs.contains(primaryDocumentID) == true
            }

            let recentGeneralTurns = sortedTurns.filter { turn in
                guard turn.id != currentUserTurn.id else { return false }
                guard let snapshot = turn.turnContextSnapshot else { return false }
                return snapshot.sourceDocumentIDs.isEmpty
            }
            .suffix(2)

            let history = mergeAndTrimTurns(
                Array(sameDocumentTurns.suffix(6)) + Array(recentGeneralTurns),
                currentUserTurn: currentUserTurn,
                stagedImages: stagedImages
            )
            return history

        case .workspaceFallback, .none, .guardrail:
            let recentTurns = Array(sortedTurns.suffix(7))
            return mergeAndTrimTurns(recentTurns, currentUserTurn: currentUserTurn, stagedImages: stagedImages)
        }
    }

    private static func mergeAndTrimTurns(
        _ turns: [MessageTurn],
        currentUserTurn: MessageTurn,
        stagedImages: [String]
    ) -> [OllamaChatMessage] {
        var uniqueByID: [UUID: MessageTurn] = [:]
        for turn in turns {
            uniqueByID[turn.id] = turn
        }
        uniqueByID[currentUserTurn.id] = currentUserTurn

        let ordered = uniqueByID.values.sorted { $0.turnIndex < $1.turnIndex }
        return ordered.compactMap { turn in
            let role: String
            switch turn.role {
            case .user: role = "user"
            case .model: role = "assistant"
            case .system: role = "system"
            }

            if turn.id == currentUserTurn.id, turn.role == .user {
                return .init(role: role, content: turn.content, images: stagedImages.isEmpty ? nil : stagedImages)
            }

            return .init(role: role, content: turn.content)
        }
    }

    private static func explicitMode(from prompt: String) -> StudyMode? {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized.contains("summarize") || normalized.contains("summary") {
            return .summarize
        }

        if normalized.contains("translate") {
            return .translate
        }

        if normalized.contains("practice question")
            || normalized.contains("practice questions")
            || normalized.contains("quiz me")
            || normalized.contains("quiz card")
            || normalized.contains("flashcard")
            || normalized.contains("study question") {
            return .practice
        }

        if normalized.contains("explain") || normalized.contains("walk me through") {
            return .explain
        }

        return nil
    }

    private static func explicitlyNamedDocument(
        in prompt: String,
        among documents: [SourceDocument]
    ) -> SourceDocument? {
        let normalizedPrompt = normalizeLookupKey(prompt)

        return documents
            .compactMap { document -> (SourceDocument, Int)? in
                let keys = matchingKeys(for: document)
                let matchLength = keys
                    .filter { normalizedPrompt.contains($0) }
                    .map(\.count)
                    .max()

                guard let matchLength else { return nil }
                return (document, matchLength)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.name.count > rhs.0.name.count
                }
                return lhs.1 > rhs.1
            }
            .first?
            .0
    }

    private static func matchingKeys(for document: SourceDocument) -> [String] {
        let fullName = normalizeLookupKey(document.name)
        let stem = normalizeLookupKey((document.name as NSString).deletingPathExtension)
        return [fullName, stem]
            .filter { $0.count >= 4 }
            .uniqued()
    }

    private static func uniqueDocuments(_ documents: [SourceDocument]) -> [SourceDocument] {
        var seen = Set<UUID>()
        return documents.filter { seen.insert($0.id).inserted }
    }

    private static func normalizeLookupKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lastAssistantTurn(in session: ChatSession) -> MessageTurn? {
        session.messages
            .sorted { $0.turnIndex < $1.turnIndex }
            .last(where: { $0.role == .model })
    }
}

enum ChatTranscriptExporter {
    static func markdown(session: ChatSession, turns: [MessageTurn]) -> String {
        let sortedTurns = turns.sorted { $0.turnIndex < $1.turnIndex }

        let header = """
        # \(session.title)
        _Created: \(session.createdAt.formatted()) | Session Default: \(session.studyMode.displayName)_

        ---

        """

        let body = sortedTurns.map { turn -> String in
            let title = turn.role == .user
                ? "**You**"
                : "**MaqkrsTutor (\(turn.modelIdentifier ?? session.modelIdentifier))**"

            var sections: [String] = [title]

            if let snapshot = turn.turnContextSnapshot {
                sections.append(
                    "_Mode: \(snapshot.resolvedMode.displayName) | Language: \(snapshot.resolvedLanguage) | Source: \(snapshot.sourceSummary)_"
                )
            }

            if let thought = turn.thoughtProcess, !thought.isEmpty {
                sections.append("<details><summary>Reasoning</summary>\n\n\(thought)\n</details>")
            }

            if !turn.groundingEvidence.isEmpty {
                let evidence = turn.groundingEvidence.map {
                    "- \($0.sourceFile)#\($0.chunkIndex): \($0.snippet)"
                }.joined(separator: "\n")
                sections.append("**Grounding Evidence**\n\(evidence)")
            }

            sections.append(turn.content)
            return sections.joined(separator: "\n\n")
        }
        .joined(separator: "\n\n---\n\n")

        return header + body
    }
}

private struct PromptFlags {
    let normalized: String

    init(prompt: String) {
        self.normalized = prompt.lowercased()
    }

    var referencesDeicticDocument: Bool {
        documentPhrases.contains { normalized.contains($0) }
    }

    var prefersAssistantResponseSource: Bool {
        guard normalized.contains("translate") else { return false }
        if referencesDeicticDocument { return false }
        return normalized == "translate"
            || normalized == "translate this"
            || normalized.hasPrefix("translate this ")
    }

    private var documentPhrases: [String] {
        [
            "this pdf",
            "this document",
            "this paper",
            "this file",
            "this material",
            "that pdf",
            "that document",
            "that paper"
        ]
    }
}

private extension SupportedLanguage {
    var matchPhrases: [String] {
        switch self {
        case .english:
            return ["english"]
        case .turkish:
            return ["turkish"]
        case .hindi:
            return ["hindi"]
        case .swahili:
            return ["swahili"]
        case .mandarin:
            return ["mandarin", "chinese"]
        case .bengali:
            return ["bengali", "bangla"]
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
