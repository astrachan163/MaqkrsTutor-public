//
//  ChatView.swift
//  MaqkrsTutor
//
//  UI/Views — Workspace-aware chat surface
//

import SwiftUI
import SwiftData
import MarkdownUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: ChatSession
    @Bindable var modelManager: ModelManager

    @Environment(VoiceManager.self) private var voiceManager
    @Environment(DocumentIngestionManager.self) private var ingestionManager
    @Query(sort: \SourceDocument.ingestedAt, order: .reverse) private var allDocuments: [SourceDocument]

    @AppStorage("targetLanguage") private var targetLanguage: String = SupportedLanguage.english.rawValue

    @State private var inputText: String = ""
    @State private var isGenerating = false
    @State private var isDropTargeted = false
    @State private var isFileImporterPresented = false
    @State private var stagedFiles: [StagedAttachment] = []
    @State private var uploadNotice: String?

    @FocusState private var isInputFocused: Bool

    private var sortedMessages: [MessageTurn] {
        session.messages.sorted { $0.turnIndex < $1.turnIndex }
    }

    private var workspaceDocuments: [SourceDocument] {
        guard let workspaceID = session.workspace?.id else { return [] }
        return allDocuments.filter {
            $0.workspace?.id == workspaceID && $0.isPrimaryStudyMaterial
        }
    }

    private var activeEvidence: [GroundingEvidence] {
        if isGenerating, !modelManager.activeGroundingEvidence.isEmpty {
            return modelManager.activeGroundingEvidence
        }
        return sortedMessages.last(where: { $0.role == .model })?.groundingEvidence ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(
                session: session,
                modelManager: modelManager,
                documents: workspaceDocuments,
                evidence: activeEvidence,
                targetLanguage: targetLanguage
            )

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sortedMessages) { message in
                            MessageBubbleView(
                                message: message,
                                sessionModelId: session.modelIdentifier
                            )
                            .id(message.id)
                        }

                        if case .streaming(let partialText, let partialThought) = modelManager.state {
                            StreamingBubbleView(
                                partialText: partialText,
                                partialThought: partialThought,
                                modelId: session.modelIdentifier,
                                evidence: modelManager.activeGroundingEvidence
                            )
                            .id("streaming")
                        } else if case .loading = modelManager.state {
                            LoadingIndicatorView()
                                .id("loading")
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .onChange(of: sortedMessages.count) { _, _ in
                    withAnimation(.smooth) {
                        if let last = sortedMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: modelManager.state) { _, newState in
                    withAnimation(.smooth) {
                        if case .streaming = newState {
                            proxy.scrollTo("streaming", anchor: .bottom)
                        } else if case .loading = newState {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }

            if !stagedFiles.isEmpty {
                AttachmentChipBarView(stagedFiles: $stagedFiles)
            }

            if let progress = ingestionManager.ingestionProgress {
                ProgressView(value: progress) {
                    Text(ingestionManager.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }

            if let uploadNotice {
                Text(uploadNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
            }

            ChatComposerView(
                inputText: $inputText,
                isGenerating: $isGenerating,
                stagedFiles: $stagedFiles,
                isFileImporterPresented: $isFileImporterPresented,
                studyMode: Binding(
                    get: { session.studyMode },
                    set: { session.studyMode = $0 }
                ),
                onSend: sendMessage
            )
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleFileDrop)
        .overlay(alignment: .center) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Color.accentColor.opacity(0.08).clipShape(.rect(cornerRadius: 18)))
                    .overlay {
                        Label("Drop Files to Add Study Material", systemImage: "arrow.down.doc.fill")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(24)
            }
        }
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.pdf, .plainText, .sourceCode, .image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let (supported, rejected) = splitSupportedAttachments(from: urls)
                withAnimation(.smooth) {
                    stagedFiles += supported
                }
                updateUploadNotice(forRejectedCount: rejected.count)
            }
        }
        .alert(
            "Inference Error",
            isPresented: .init(
                get: { if case .error = modelManager.state { return true }; return false },
                set: { if !$0 { modelManager.state = .idle } }
            )
        ) {
            Button("OK") { modelManager.state = .idle }
        } message: {
            if case .error(let message) = modelManager.state {
                Text(message)
            }
        }
    }
}

// MARK: - Actions

private extension ChatView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: exportChat) {
                Label("Export Chat", systemImage: "square.and.arrow.up")
            }
        }

        ToolbarItem(placement: .automatic) {
            if isGenerating {
                Button {
                    modelManager.cancelGeneration()
                    voiceManager.stop()
                    isGenerating = false
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let resolvedModel = modelManager.resolveModelIdentifier(session.modelIdentifier)
        session.modelIdentifier = resolvedModel
        session.workspace = session.workspace ?? WorkspaceBootstrap.ensureDefaultWorkspace(in: modelContext)
        let isFirstUserMessage = sortedMessages.isEmpty

        let prompt = trimmed
        inputText = ""
        uploadNotice = nil

        let userTurn = MessageTurn(
            role: .user,
            content: prompt,
            turnIndex: sortedMessages.count,
            session: session
        )
        modelContext.insert(userTurn)
        session.messages.append(userTurn)
        session.lastActivityAt = Date()
        session.workspace?.lastActivityAt = Date()

        if isFirstUserMessage {
            session.title = String(prompt.prefix(50))
        }

        let imageAttachments = stagedFiles.filter { $0.type == .image }
        let base64Images = imageAttachments.compactMap { attachment -> String? in
            guard let data = try? Data(contentsOf: attachment.url) else { return nil }
            return data.base64EncodedString()
        }

        let ingestableFiles = stagedFiles.filter(\.isStudySource)
        withAnimation(.smooth) {
            stagedFiles.removeAll()
        }

        isGenerating = true
        var fullResponse = ""
        var fullThought = ""

        Task {
            let workspace = session.workspace ?? WorkspaceBootstrap.ensureDefaultWorkspace(in: modelContext)
            var ingestedDocuments: [SourceDocument] = []

            if !ingestableFiles.isEmpty {
                ingestedDocuments = await ingestionManager.ingest(
                    urls: ingestableFiles.map(\.url),
                    into: workspace
                )
                applyFocusAfterIngestion(ingestedDocuments)
            }

            let availableDocuments = uniqueDocumentsPreservingOrder(workspaceDocuments + ingestedDocuments)

            let resolvedTurn = ChatOrchestrator.resolveTurn(
                session: session,
                currentUserTurn: userTurn,
                availableDocuments: availableDocuments,
                stagedDocuments: ingestedDocuments,
                stagedImages: base64Images,
                selectedLanguage: targetLanguage
            )
            userTurn.turnContextSnapshot = resolvedTurn.turnContextSnapshot

            if let guardrailMessage = resolvedTurn.guardrailMessage {
                appendGuardrailMessage(
                    text: guardrailMessage,
                    snapshot: resolvedTurn.turnContextSnapshot
                )
                isGenerating = false
                modelManager.state = .idle
                return
            }

            let stream = modelManager.streamChat(
                resolvedTurn: resolvedTurn,
                modelIdentifier: resolvedModel,
                vectorStore: ingestionManager.vectorStore
            )

            for await chunk in stream {
                fullResponse += chunk
                if case .streaming(_, let thought) = modelManager.state {
                    fullThought = thought
                }
            }

            switch modelManager.state {
            case .complete(_, let thought):
                fullThought = thought
            case .streaming(_, let thought):
                fullThought = thought
            case .error, .idle:
                isGenerating = false
                return
            default:
                break
            }

            let finalEvidence = modelManager.activeGroundingEvidence
            guard !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !fullThought.isEmpty else {
                isGenerating = false
                return
            }

            let modelTurn = MessageTurn(
                role: .model,
                content: fullResponse,
                thoughtProcess: fullThought.isEmpty ? nil : fullThought,
                modelIdentifier: resolvedModel,
                turnIndex: sortedMessages.count,
                evidenceJSON: nil,
                session: session
            )
            modelTurn.groundingEvidence = finalEvidence
            modelTurn.turnContextSnapshot = resolvedTurn.turnContextSnapshot
            modelContext.insert(modelTurn)
            session.messages.append(modelTurn)
            session.lastActivityAt = Date()
            session.workspace?.lastActivityAt = Date()

            persistArtifactIfNeeded(
                for: resolvedTurn.mode,
                content: fullResponse,
                sourceDocumentID: resolvedTurn.sourceManifest.primaryDocumentID
            )

            isGenerating = false
        }
    }

    func appendGuardrailMessage(text: String, snapshot: TurnContextSnapshot? = nil) {
        let turn = MessageTurn(
            role: .model,
            content: text,
            modelIdentifier: session.modelIdentifier,
            turnIndex: sortedMessages.count,
            session: session
        )
        turn.turnContextSnapshot = snapshot
        modelContext.insert(turn)
        session.messages.append(turn)
    }

    func persistArtifactIfNeeded(
        for studyMode: StudyMode,
        content: String,
        sourceDocumentID: UUID?
    ) {
        let artifactKind: StudyArtifactKind?
        switch studyMode {
        case .summarize: artifactKind = .summary
        case .translate: artifactKind = .translation
        case .practice: artifactKind = .practiceSet
        case .tutor, .explain: artifactKind = nil
        }

        guard let artifactKind,
              let workspace = session.workspace else {
            return
        }

        let sourceDocument = sourceDocument(for: sourceDocumentID)
        let titleBase = sourceDocument?.name ?? session.title
        let artifact = StudyArtifact(
            title: "\(studyMode.displayName) · \(titleBase)",
            kind: artifactKind,
            content: content,
            workspace: workspace,
            sourceDocument: sourceDocument,
            originatingSession: session
        )
        modelContext.insert(artifact)
    }

    func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let attachment: StagedAttachment?
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    attachment = StagedAttachment(url: url)
                } else if let url = item as? URL {
                    attachment = StagedAttachment(url: url)
                } else {
                    attachment = nil
                }

                guard let attachment else { return }

                Task { @MainActor in
                    if attachment.isSupportedUpload {
                        withAnimation(.smooth) {
                            stagedFiles.append(attachment)
                        }
                        uploadNotice = nil
                    } else {
                        updateUploadNotice(forRejectedCount: 1)
                    }
                }
            }
        }

        return true
    }

    func exportChat() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.title).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? ChatTranscriptExporter
                .markdown(session: session, turns: sortedMessages)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func applyFocusAfterIngestion(_ documents: [SourceDocument]) {
        guard !documents.isEmpty else { return }

        if documents.count == 1, let document = documents.first {
            session.focusedDocument = document
            document.lastUsedAt = Date()
        }
    }

    func sourceDocument(for documentID: UUID?) -> SourceDocument? {
        guard let documentID else { return nil }
        if session.focusedDocument?.id == documentID {
            return session.focusedDocument
        }
        return allDocuments.first { $0.id == documentID }
    }

    func uniqueDocumentsPreservingOrder(_ documents: [SourceDocument]) -> [SourceDocument] {
        var seen = Set<UUID>()
        return documents.filter { seen.insert($0.id).inserted }
    }

    func splitSupportedAttachments(from urls: [URL]) -> (supported: [StagedAttachment], rejected: [URL]) {
        let attachments = urls.map(StagedAttachment.init(url:))
        let supported = attachments.filter(\.isSupportedUpload)
        let rejected = attachments.filter { !$0.isSupportedUpload }.map(\.url)
        return (supported, rejected)
    }

    func updateUploadNotice(forRejectedCount rejectedCount: Int) {
        if rejectedCount > 0 {
            uploadNotice = "Only PDFs, text/Markdown, code files, and images are supported in macOS v1."
        } else {
            uploadNotice = nil
        }
    }
}

// MARK: - Header

private struct ChatHeaderView: View {
    @Bindable var session: ChatSession
    @Bindable var modelManager: ModelManager
    let documents: [SourceDocument]
    let evidence: [GroundingEvidence]
    let targetLanguage: String

    private var groundingSummary: String {
        guard !evidence.isEmpty else { return "Ungrounded" }
        let sources = Set(evidence.map(\.sourceFile)).count
        return "Grounded in \(evidence.count) chunks from \(sources) source\(sources == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.title3.weight(.semibold))
                    Text(session.workspace?.name ?? WorkspaceBootstrap.defaultWorkspaceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(modelManager.resolveModelIdentifier(session.modelIdentifier))
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 10) {
                HeaderChip(
                    title: "Preset: \(session.studyMode.displayName)",
                    systemImage: session.studyMode.systemImage,
                    tint: .orange
                )

                HeaderChip(
                    title: session.focusedDocument?.name ?? "No active document",
                    systemImage: session.focusedDocument?.fileType.systemImage ?? "doc.badge.questionmark",
                    tint: .blue
                )

                HeaderChip(
                    title: targetLanguage,
                    systemImage: "globe",
                    tint: .purple
                )

                HeaderChip(
                    title: groundingSummary,
                    systemImage: evidence.isEmpty ? "exclamationmark.triangle" : "checkmark.shield",
                    tint: evidence.isEmpty ? .secondary : .green
                )
            }

            if !documents.isEmpty {
                Picker("Document Focus", selection: Binding<UUID?>(
                    get: { session.focusedDocument?.id },
                    set: { newValue in
                        session.focusedDocument = documents.first { $0.id == newValue }
                    }
                )) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(documents) { document in
                        Text(document.name).tag(Optional(document.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.03))
    }
}

private struct HeaderChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

// MARK: - Composer

private struct ChatComposerView: View {
    @Binding var inputText: String
    @Binding var isGenerating: Bool
    @Binding var stagedFiles: [StagedAttachment]
    @Binding var isFileImporterPresented: Bool
    @Binding var studyMode: StudyMode
    let onSend: () -> Void

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StudyMode.allCases) { mode in
                        Button {
                            studyMode = mode
                        } label: {
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(mode == studyMode
                                              ? Color.accentColor.opacity(0.18)
                                              : Color.primary.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                TextField("Ask a course-aware question…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .disabled(isGenerating)
                    .onSubmit {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onSend()
                        }
                    }

                Button(action: onSend) {
                    Image(systemName: isGenerating ? "hourglass.circle" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.04))
    }
}

private struct AttachmentChipBarView: View {
    @Binding var stagedFiles: [StagedAttachment]

    private var summaryText: String {
        let documentCount = stagedFiles.filter(\.isStudySource).count
        let imageCount = stagedFiles.filter { $0.type == .image }.count

        var parts: [String] = []
        if documentCount > 0 {
            parts.append("\(documentCount) study document\(documentCount == 1 ? "" : "s")")
        }
        if imageCount > 0 {
            parts.append("\(imageCount) image attachment\(imageCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summaryText, systemImage: "paperclip")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stagedFiles) { file in
                        AttachmentChipView(attachment: file) {
                            withAnimation(.smooth) {
                                stagedFiles.removeAll { $0.id == file.id }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
        }
        .background(Color.primary.opacity(0.03))
    }
}

private struct AttachmentChipView: View {
    let attachment: StagedAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.type.systemImage)
                .font(.caption2)
            Text(attachment.name)
                .font(.caption2)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
    }
}

// MARK: - Messages

private struct MessageBubbleView: View {
    let message: MessageTurn
    let sessionModelId: String

    @Environment(VoiceManager.self) private var voiceManager
    @AppStorage("targetLanguage") private var targetLanguage: String = SupportedLanguage.english.rawValue
    @State private var showReasoning = false
    @State private var showEvidence = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 70)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                header

                if let thought = message.thoughtProcess, !thought.isEmpty {
                    DisclosureGroup(isExpanded: $showReasoning) {
                        Markdown(thought)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.orange.opacity(0.07))
                                    .strokeBorder(Color.orange.opacity(0.18), lineWidth: 0.5)
                            )
                    } label: {
                        Label("Reasoning", systemImage: "brain")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Group {
                    if message.role == .model {
                        Markdown(message.content)
                            .textSelection(.enabled)
                    } else {
                        Text(message.content)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(message.role == .user ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                )

                if message.role == .model, !message.groundingEvidence.isEmpty {
                    DisclosureGroup(isExpanded: $showEvidence) {
                        EvidenceListView(evidence: message.groundingEvidence)
                    } label: {
                        Label(
                            "Grounded in \(message.groundingEvidence.count) chunk\(message.groundingEvidence.count == 1 ? "" : "s")",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }

                footer
            }

            if message.role == .model {
                Spacer(minLength: 70)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if message.role != .user {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
            }
            Text(message.role == .user ? "You" : "MaqkrsTutor")
                .font(.caption)
                .fontWeight(.semibold)

            if message.role == .model {
                Text(message.modelIdentifier ?? sessionModelId)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)

                if let snapshot = message.turnContextSnapshot {
                    Text(snapshot.resolvedMode.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                        .foregroundStyle(.orange)
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(message.timestamp, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let snapshot = message.turnContextSnapshot {
                Text(snapshot.sourceSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if message.role == .model {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)

                let isActiveSpeaker = voiceManager.speakingMessageId == message.id
                Button {
                    let language = SupportedLanguage.from(rawValue: targetLanguage).bcp47Code
                    voiceManager.toggle(text: message.content, language: language, messageId: message.id)
                } label: {
                    Image(systemName: isActiveSpeaker ? "speaker.wave.3.fill" : "speaker.wave.2")
                        .font(.caption)
                        .foregroundStyle(isActiveSpeaker ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct EvidenceListView: View {
    let evidence: [GroundingEvidence]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(evidence) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.sourceFile)#\(item.chunkIndex)")
                        .font(.caption.weight(.semibold))
                    if let location = [item.sectionTitle, item.pageLabel].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                        Text(location)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.06))
                )
            }
        }
    }
}

private struct StreamingBubbleView: View {
    let partialText: String
    let partialThought: String
    let modelId: String
    let evidence: [GroundingEvidence]

    @State private var showReasoning = true
    @State private var showEvidence = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                    Text("MaqkrsTutor")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(modelId)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                    ProgressView()
                        .scaleEffect(0.6)
                }
                .foregroundStyle(.secondary)

                if !partialThought.isEmpty {
                    DisclosureGroup(isExpanded: $showReasoning) {
                        Markdown(partialThought)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.orange.opacity(0.07))
                            )
                    } label: {
                        Label("Reasoning", systemImage: "brain")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !partialText.isEmpty {
                    Markdown(partialText)
                        .textSelection(.enabled)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }

                if !evidence.isEmpty {
                    DisclosureGroup(isExpanded: $showEvidence) {
                        EvidenceListView(evidence: evidence)
                    } label: {
                        Label(
                            "Grounded in \(evidence.count) chunk\(evidence.count == 1 ? "" : "s")",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }
            }

            Spacer(minLength: 70)
        }
    }
}

private struct LoadingIndicatorView: View {
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Preparing grounded response…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            Spacer()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    let schema = Schema([
        CourseWorkspace.self,
        SourceDocument.self,
        ChatSession.self,
        MessageTurn.self,
        StudyArtifact.self,
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])

    let workspace = CourseWorkspace(name: "Operating Systems")
    let document = SourceDocument(
        name: "Distributed Systems Paper.pdf",
        sourceFile: "Distributed Systems Paper.pdf",
        fileType: .pdf,
        chunkCount: 143,
        workspace: workspace
    )
    let session = ChatSession(
        title: "Summarize this paper",
        workspace: workspace,
        focusedDocument: document,
        studyMode: .summarize
    )

    container.mainContext.insert(workspace)
    container.mainContext.insert(document)
    container.mainContext.insert(session)

    let user = MessageTurn(
        role: .user,
        content: "Summarize this research paper.",
        turnIndex: 0,
        session: session
    )
    let assistant = MessageTurn(
        role: .model,
        content: "## Summary\n\nThis paper evaluates a grounded tutor workflow for course-specific learning.",
        thoughtProcess: "- Check the focused document\n- Build a grounded summary\n- Surface methodology and results",
        modelIdentifier: "gemma4:e4b-it-q4_K_M",
        turnIndex: 1,
        session: session
    )
    assistant.groundingEvidence = [
        GroundingEvidence(
            documentID: document.id,
            sourceFile: document.name,
            chunkID: UUID(),
            chunkIndex: 3,
            sectionTitle: "Results",
            pageLabel: "Page 2",
            score: 0.08,
            snippet: "The grounded tutor improved summary fidelity and reduced document-context misses."
        )
    ]
    container.mainContext.insert(user)
    container.mainContext.insert(assistant)
    session.messages = [user, assistant]

    return NavigationStack {
        ChatView(session: session, modelManager: ModelManager())
            .environment(VoiceManager())
            .environment(
                try! DocumentIngestionManager(
                    vectorStore: VectorStore(),
                    modelManager: ModelManager(),
                    modelContext: container.mainContext
                )
            )
    }
    .modelContainer(container)
    .frame(width: 900, height: 700)
}
