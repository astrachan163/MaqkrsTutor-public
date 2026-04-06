//
//  MaqkrsTutorTests.swift
//  MaqkrsTutorTests
//

import Foundation
import SwiftData
import Testing
@testable import MaqkrsTutor

struct MaqkrsTutorTests {

    @Test
    func staleModelIdentifierFallsBackToInstalledDefault() {
        let installedModels = [
            "gemma4:e4b-it-q4_K_M",
            "gemma4:31b-it-q4_K_M"
        ]

        let resolved = ModelManager.resolveModelIdentifier(
            "gemma3:12b",
            installedModelIDs: installedModels
        )

        #expect(resolved == "gemma4:e4b-it-q4_K_M")
    }

    @Test
    func preferredInstalledModelUsesCuratedOrder() {
        let installedModels = [
            "gemma4:31b-it-q4_K_M",
            "gemma4:e4b-it-q4_K_M",
            "gemma4:26b-a4b-it-q4_K_M"
        ]

        let preferred = ModelManager.preferredInstalledModel(from: installedModels)

        #expect(preferred == "gemma4:e4b-it-q4_K_M")
    }

    @Test
    func nativeThinkingFieldSeparatesThoughtFromVisibleResponse() {
        var accumulator = ChatStreamAccumulator()

        let firstDelta = accumulator.consume(contentToken: "", thinkingToken: "Plan first. ")
        let secondDelta = accumulator.consume(contentToken: "Final answer.", thinkingToken: nil)
        let finalDelta = accumulator.finish()

        #expect(firstDelta.isEmpty)
        #expect(secondDelta == "Final answer.")
        #expect(finalDelta.isEmpty)
        #expect(accumulator.fullThought == "Plan first. ")
        #expect(accumulator.fullResponse == "Final answer.")
    }

    @Test
    func legacyThinkTagsStillParseAsFallback() {
        var accumulator = ChatStreamAccumulator()

        let firstDelta = accumulator.consume(contentToken: "<think>Reason")
        let secondDelta = accumulator.consume(contentToken: "ing</think>Answer")
        let finalDelta = accumulator.finish()

        #expect(firstDelta.isEmpty)
        #expect(secondDelta == "Answer")
        #expect(finalDelta.isEmpty)
        #expect(accumulator.fullThought == "Reasoning")
        #expect(accumulator.fullResponse == "Answer")
    }

    @Test
    @MainActor
    func orphanSessionsAreMigratedIntoDefaultWorkspace() throws {
        let schema = Schema([
            CourseWorkspace.self,
            SourceDocument.self,
            ChatSession.self,
            MessageTurn.self,
            StudyArtifact.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])

        let session = ChatSession(title: "Legacy Session")
        container.mainContext.insert(session)

        let workspace = WorkspaceBootstrap.ensureDefaultWorkspace(in: container.mainContext)

        #expect(workspace.name == WorkspaceBootstrap.defaultWorkspaceName)
        #expect(session.workspace?.id == workspace.id)
    }

    @Test
    @MainActor
    func summarizationStrategyUsesFocusedDocumentAndGuardrailsWithoutOne() {
        let workspaceID = UUID()
        let documentID = UUID()

        let focusedRequest = ChatGroundingRequest(
            studyMode: .tutor,
            workspaceID: workspaceID,
            focusedDocumentID: documentID,
            focusedDocumentName: "Paper.pdf",
            language: SupportedLanguage.english.rawValue,
            stagedImages: []
        )

        let unfocusedRequest = ChatGroundingRequest(
            studyMode: .tutor,
            workspaceID: workspaceID,
            focusedDocumentID: nil,
            focusedDocumentName: nil,
            language: SupportedLanguage.english.rawValue,
            stagedImages: []
        )

        #expect(focusedRequest.strategy(for: "Summarize this research paper") == .documentSummary(documentID))
        #expect(unfocusedRequest.strategy(for: "Summarize this research paper") == .requiresDocumentSelection(.summarize))
    }

    @Test
    func modelDescriptorClassifiesEmbeddingModelsAsAdvancedOnly() {
        let descriptor = ModelManager.descriptor(for: "nomic-embed-text:v1.5")

        #expect(!descriptor.supportsChat)
        #expect(descriptor.supportsEmbedding)
        #expect(descriptor.visibility == .advanced)
    }

    @Test
    @MainActor
    func documentScopedRetrievalOnlyReturnsChunksFromFocusedDocument() async throws {
        let workspaceID = UUID()
        let documentA = UUID()
        let documentB = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try VectorStore(directory: directory)
        try await store.open()

        try await store.insert(chunks: [
            EmbeddingChunk(
                text: "Doc A chunk",
                sourceFile: "A.pdf",
                workspaceID: workspaceID,
                documentID: documentA,
                chunkID: UUID(),
                chunkIndex: 0,
                chunkType: "text",
                sectionTitle: "A",
                pageLabel: "Page 1",
                embedding: embedding(seed: 1)
            ),
            EmbeddingChunk(
                text: "Doc B chunk",
                sourceFile: "B.pdf",
                workspaceID: workspaceID,
                documentID: documentB,
                chunkID: UUID(),
                chunkIndex: 0,
                chunkType: "text",
                sectionTitle: "B",
                pageLabel: "Page 1",
                embedding: embedding(seed: 1)
            )
        ])

        let results = try await store.retrieveNearest(
            queryEmbedding: embedding(seed: 1),
            k: 5,
            scope: .document(documentA)
        )

        #expect(results.count == 1)
        #expect(results.first?.documentID == documentA)
        #expect(results.first?.sourceFile == "A.pdf")
    }

    @Test
    @MainActor
    func hybridRetrievalPrefersFocusedDocumentBeforeWorkspaceFallback() async throws {
        let workspaceID = UUID()
        let documentA = UUID()
        let documentB = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try VectorStore(directory: directory)
        try await store.open()

        try await store.insert(chunks: [
            EmbeddingChunk(
                text: "Focused chunk",
                sourceFile: "Focused.pdf",
                workspaceID: workspaceID,
                documentID: documentA,
                chunkID: UUID(),
                chunkIndex: 0,
                chunkType: "text",
                sectionTitle: nil,
                pageLabel: nil,
                embedding: embedding(seed: 1)
            ),
            EmbeddingChunk(
                text: "Workspace fallback",
                sourceFile: "Other.pdf",
                workspaceID: workspaceID,
                documentID: documentB,
                chunkID: UUID(),
                chunkIndex: 0,
                chunkType: "text",
                sectionTitle: nil,
                pageLabel: nil,
                embedding: embedding(seed: 1)
            )
        ])

        let results = try await store.retrieveNearest(
            queryEmbedding: embedding(seed: 1),
            k: 2,
            scope: .hybrid(documentID: documentA, workspaceID: workspaceID)
        )

        #expect(results.count == 2)
        #expect(results.first?.documentID == documentA)
        #expect(results.last?.documentID == documentB)
    }

    @Test
    @MainActor
    func summarizePromptOverridesPracticeDefaultAndUsesFocusedDocument() {
        let workspace = CourseWorkspace(name: "My Studies")
        let focusedDocument = makeDocument(
            name: "Paper.pdf",
            fileType: .pdf,
            chunkCount: 0,
            directContextText: "Paper content",
            workspace: workspace
        )
        let session = ChatSession(
            title: "Session",
            workspace: workspace,
            focusedDocument: focusedDocument,
            studyMode: .practice
        )
        let userTurn = MessageTurn(
            role: .user,
            content: "summarize this",
            turnIndex: 0,
            session: session
        )
        session.messages = [userTurn]

        let resolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: userTurn,
            availableDocuments: [focusedDocument],
            stagedDocuments: [],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.english.rawValue
        )

        #expect(resolved.mode == .summarize)
        #expect(resolved.sourceManifest.kind == .focusedDocument)
        #expect(resolved.sourceManifest.primaryDocumentID == focusedDocument.id)
        #expect(resolved.turnContextSnapshot.resolvedMode == .summarize)
        #expect(resolved.turnContextSnapshot.sourceDocumentIDs == [focusedDocument.id])
    }

    @Test
    @MainActor
    func focusSwitchScopesHistoryToCurrentDocumentContext() {
        let workspace = CourseWorkspace(name: "My Studies")
        let documentA = makeDocument(name: "Agent Personas.md", fileType: .text, workspace: workspace)
        let documentB = makeDocument(name: "Firewall Exploration Lab Report.pdf", fileType: .pdf, workspace: workspace)
        let session = ChatSession(
            title: "Session",
            workspace: workspace,
            focusedDocument: documentB,
            studyMode: .practice
        )

        let oldDocUser = MessageTurn(role: .user, content: "make practice questions", turnIndex: 0, session: session)
        oldDocUser.turnContextSnapshot = makeSnapshot(mode: .practice, sourceKind: .focusedDocument, documents: [documentA], focusedDocument: documentA)

        let oldDocModel = MessageTurn(role: .model, content: "Questions for Agent Personas", turnIndex: 1, session: session)
        oldDocModel.turnContextSnapshot = makeSnapshot(mode: .practice, sourceKind: .focusedDocument, documents: [documentA], focusedDocument: documentA)

        let generalUser = MessageTurn(role: .user, content: "thanks", turnIndex: 2, session: session)
        generalUser.turnContextSnapshot = makeSnapshot(mode: .tutor, sourceKind: .none, documents: [], focusedDocument: documentA)

        let generalModel = MessageTurn(role: .model, content: "You're welcome.", turnIndex: 3, session: session)
        generalModel.turnContextSnapshot = makeSnapshot(mode: .tutor, sourceKind: .none, documents: [], focusedDocument: documentA)

        let currentUser = MessageTurn(
            role: .user,
            content: "make practice questions for this pdf",
            turnIndex: 4,
            session: session
        )

        session.messages = [oldDocUser, oldDocModel, generalUser, generalModel, currentUser]

        let resolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: currentUser,
            availableDocuments: [documentA, documentB],
            stagedDocuments: [],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.english.rawValue
        )

        let historyContents = resolved.historyMessages.map(\.content)

        #expect(resolved.mode == .practice)
        #expect(resolved.sourceManifest.primaryDocumentID == documentB.id)
        #expect(!historyContents.contains("Questions for Agent Personas"))
        #expect(!historyContents.contains("make practice questions"))
        #expect(historyContents.contains("thanks"))
        #expect(historyContents.contains("You're welcome."))
        #expect(historyContents.last == "make practice questions for this pdf")
    }

    @Test
    @MainActor
    func translateThisUsesLastAssistantMessageAndExplicitLanguage() {
        let session = ChatSession(title: "Session", studyMode: .tutor)

        let assistantTurn = MessageTurn(
            role: .model,
            content: "Original assistant response.",
            turnIndex: 0,
            session: session
        )
        assistantTurn.turnContextSnapshot = makeSnapshot(mode: .tutor, sourceKind: .none)

        let currentUser = MessageTurn(
            role: .user,
            content: "translate this to turkish",
            turnIndex: 1,
            session: session
        )
        session.messages = [assistantTurn, currentUser]

        let resolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: currentUser,
            availableDocuments: [],
            stagedDocuments: [],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.english.rawValue
        )

        #expect(resolved.mode == .translate)
        #expect(resolved.language == SupportedLanguage.turkish.rawValue)
        #expect(resolved.explicitLanguageOverride)
        #expect(resolved.sourceManifest.kind == .assistantMessage)
        #expect(resolved.historyMessages.count == 2)
        #expect(resolved.historyMessages.first?.content == "Original assistant response.")
    }

    @Test
    @MainActor
    func bareTranslateUsesSelectedMenuLanguageWhileTranslateThisPdfUsesFocusedDocument() {
        let workspace = CourseWorkspace(name: "My Studies")
        let document = makeDocument(name: "Firewall.pdf", fileType: .pdf, directContextText: "Firewall lab", workspace: workspace)
        let session = ChatSession(
            title: "Session",
            workspace: workspace,
            focusedDocument: document,
            studyMode: .tutor
        )

        let assistantTurn = MessageTurn(role: .model, content: "Hello world", turnIndex: 0, session: session)
        assistantTurn.turnContextSnapshot = makeSnapshot(mode: .tutor, sourceKind: .none)

        let bareTranslateTurn = MessageTurn(role: .user, content: "translate", turnIndex: 1, session: session)
        session.messages = [assistantTurn, bareTranslateTurn]

        let bareResolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: bareTranslateTurn,
            availableDocuments: [document],
            stagedDocuments: [],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.hindi.rawValue
        )

        #expect(bareResolved.language == SupportedLanguage.hindi.rawValue)
        #expect(bareResolved.sourceManifest.kind == .assistantMessage)

        let documentTranslateTurn = MessageTurn(role: .user, content: "translate this pdf", turnIndex: 2, session: session)
        session.messages = [assistantTurn, bareTranslateTurn, documentTranslateTurn]

        let documentResolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: documentTranslateTurn,
            availableDocuments: [document],
            stagedDocuments: [],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.hindi.rawValue
        )

        #expect(documentResolved.sourceManifest.kind == .focusedDocument)
        #expect(documentResolved.sourceManifest.primaryDocumentID == document.id)
    }

    @Test
    @MainActor
    func explicitDocumentAndSingleStagedDocumentOverrideFocusedDocument() {
        let workspace = CourseWorkspace(name: "My Studies")
        let focusedDocument = makeDocument(name: "Firewall Exploration Lab Report.pdf", fileType: .pdf, workspace: workspace)
        let namedDocument = makeDocument(name: "Agent Personas.md", fileType: .text, workspace: workspace)
        let stagedDocument = makeDocument(name: "Assignment4_Strachan.pdf", fileType: .pdf, workspace: workspace)
        let session = ChatSession(
            title: "Session",
            workspace: workspace,
            focusedDocument: focusedDocument,
            studyMode: .practice
        )

        let explicitTurn = MessageTurn(
            role: .user,
            content: "make practice questions for Agent Personas.md",
            turnIndex: 0,
            session: session
        )
        session.messages = [explicitTurn]

        let explicitResolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: explicitTurn,
            availableDocuments: [focusedDocument, namedDocument, stagedDocument],
            stagedDocuments: [],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.english.rawValue
        )

        #expect(explicitResolved.sourceManifest.kind == .explicitDocument)
        #expect(explicitResolved.sourceManifest.primaryDocumentID == namedDocument.id)
        #expect(session.focusedDocument?.id == namedDocument.id)

        let stagedTurn = MessageTurn(
            role: .user,
            content: "summarize this",
            turnIndex: 1,
            session: session
        )
        session.messages = [explicitTurn, stagedTurn]

        let stagedResolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: stagedTurn,
            availableDocuments: [focusedDocument, namedDocument],
            stagedDocuments: [stagedDocument],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.english.rawValue
        )

        #expect(stagedResolved.sourceManifest.kind == .stagedDocument)
        #expect(stagedResolved.sourceManifest.primaryDocumentID == stagedDocument.id)
    }

    @Test
    @MainActor
    func ambiguousMultiDocumentDeicticRequestReturnsGuardrail() {
        let workspace = CourseWorkspace(name: "My Studies")
        let documentA = makeDocument(name: "A.pdf", fileType: .pdf, workspace: workspace)
        let documentB = makeDocument(name: "B.pdf", fileType: .pdf, workspace: workspace)
        let session = ChatSession(title: "Session", workspace: workspace, studyMode: .summarize)
        let currentUser = MessageTurn(role: .user, content: "summarize this pdf", turnIndex: 0, session: session)
        session.messages = [currentUser]

        let resolved = ChatOrchestrator.resolveTurn(
            session: session,
            currentUserTurn: currentUser,
            availableDocuments: [documentA, documentB],
            stagedDocuments: [documentA, documentB],
            stagedImages: [],
            selectedLanguage: SupportedLanguage.english.rawValue
        )

        #expect(resolved.guardrailMessage != nil)
        #expect(resolved.sourceManifest.kind == .none)
    }

    @Test
    @MainActor
    func transcriptExportUsesPerTurnSnapshotRatherThanSessionDefault() {
        let workspace = CourseWorkspace(name: "My Studies")
        let document = makeDocument(name: "Paper.pdf", fileType: .pdf, workspace: workspace)
        let session = ChatSession(title: "summarize this", workspace: workspace, studyMode: .practice)

        let userTurn = MessageTurn(role: .user, content: "summarize this", turnIndex: 0, session: session)
        userTurn.turnContextSnapshot = makeSnapshot(mode: .summarize, sourceKind: .focusedDocument, documents: [document], focusedDocument: document)

        let modelTurn = MessageTurn(
            role: .model,
            content: "## Summary",
            modelIdentifier: "gemma4:e2b-it-q4_K_M",
            turnIndex: 1,
            session: session
        )
        modelTurn.turnContextSnapshot = makeSnapshot(mode: .summarize, sourceKind: .focusedDocument, documents: [document], focusedDocument: document)
        modelTurn.groundingEvidence = [
            GroundingEvidence(
                documentID: document.id,
                sourceFile: document.name,
                chunkID: nil,
                chunkIndex: 0,
                sectionTitle: nil,
                pageLabel: "Page 1",
                score: 0,
                snippet: "Snippet"
            )
        ]

        let markdown = ChatTranscriptExporter.markdown(session: session, turns: [userTurn, modelTurn])

        #expect(markdown.contains("Session Default: Practice"))
        #expect(markdown.contains("_Mode: Summarize | Language: English | Source: Paper.pdf_"))
        #expect(markdown.contains("**Grounding Evidence**"))
    }

    @Test
    @MainActor
    func directOnlyDocumentShowsDirectReadyInsteadOfZeroChunkFailureState() {
        let document = makeDocument(
            name: "Agent Personas.md",
            fileType: .text,
            chunkCount: 0,
            directContextText: "Persona content"
        )

        #expect(document.readiness == .directReady)
        #expect(document.readiness.displayName == "Direct Ready")
        #expect(document.readinessSubtitle == "Direct Ready")
    }
}

private extension MaqkrsTutorTests {
    static func embedding(seed: Float) -> [Float] {
        var vector = Array(repeating: Float(0), count: VectorStoreConfig.embeddingDimension)
        vector[0] = seed
        return vector
    }

    func embedding(seed: Float) -> [Float] {
        Self.embedding(seed: seed)
    }

    @MainActor
    func makeDocument(
        name: String,
        fileType: SourceDocumentType,
        chunkCount: Int = 4,
        directContextText: String? = nil,
        workspace: CourseWorkspace? = nil
    ) -> SourceDocument {
        SourceDocument(
            name: name,
            sourceFile: name,
            fileType: fileType,
            chunkCount: chunkCount,
            directContextText: directContextText,
            workspace: workspace
        )
    }

    @MainActor
    func makeSnapshot(
        mode: StudyMode,
        language: String = SupportedLanguage.english.rawValue,
        sourceKind: SourceResolutionKind,
        documents: [SourceDocument] = [],
        focusedDocument: SourceDocument? = nil
    ) -> TurnContextSnapshot {
        TurnContextSnapshot(
            resolvedModeRawValue: mode.rawValue,
            resolvedLanguage: language,
            focusedDocumentID: focusedDocument?.id,
            focusedDocumentName: focusedDocument?.name,
            sourceKindRawValue: sourceKind.rawValue,
            sourceDocumentIDs: documents.map(\.id),
            sourceDocumentNames: documents.map(\.name),
            explicitDocumentOverride: sourceKind == .explicitDocument,
            explicitLanguageOverride: false
        )
    }
}
