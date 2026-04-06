//
//  ContentView.swift
//  MaqkrsTutor
//
//  UI/Views — Workspace-first split view shell
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \CourseWorkspace.lastActivityAt, order: .reverse)
    private var workspaces: [CourseWorkspace]

    @Query(sort: \ChatSession.lastActivityAt, order: .reverse)
    private var allSessions: [ChatSession]

    @Query(sort: \SourceDocument.ingestedAt, order: .reverse)
    private var allDocuments: [SourceDocument]

    @State private var selectedWorkspace: CourseWorkspace?
    @State private var selectedSession: ChatSession?
    @State private var modelManager = ModelManager()
    @State private var voiceManager = VoiceManager()
    @State private var ingestionManager: DocumentIngestionManager?

    @AppStorage("targetLanguage") private var targetLanguage: String = SupportedLanguage.english.rawValue

    private var workspaceSessions: [ChatSession] {
        guard let selectedWorkspace else { return [] }
        return allSessions.filter { $0.workspace?.id == selectedWorkspace.id }
    }

    private var workspaceDocuments: [SourceDocument] {
        guard let selectedWorkspace else { return [] }
        return allDocuments.filter {
            $0.workspace?.id == selectedWorkspace.id && $0.isPrimaryStudyMaterial
        }
    }

    var body: some View {
        Group {
            if let ingestionManager {
                NavigationSplitView {
                    WorkspaceSidebarView(
                        workspaces: workspaces,
                        selectedWorkspace: $selectedWorkspace,
                        selectedSession: $selectedSession,
                        sessions: workspaceSessions,
                        documents: workspaceDocuments,
                        modelManager: modelManager,
                        targetLanguage: $targetLanguage,
                        onCreateWorkspace: createWorkspace,
                        onCreateSession: createSession,
                        onDeleteSession: deleteSession(_:),
                        onFocusDocument: focusDocument(_:)
                    )
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
                } detail: {
                    detailView
                }
                .environment(voiceManager)
                .environment(ingestionManager)
            } else {
                ProgressView("Initializing workspace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await bootstrap()
        }
        .onChange(of: selectedSession?.id) { _, _ in
            syncSelectionFromSession()
            normalizeSelectedSessionModel()
        }
        .onChange(of: selectedWorkspace?.id) { _, _ in
            syncSelectionFromWorkspace()
        }
        .onChange(of: modelManager.installedModels) { _, _ in
            normalizeSelectedSessionModel()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let selectedSession {
            ChatView(session: selectedSession, modelManager: modelManager)
        } else {
            ContentUnavailableView {
                Label("No Session Selected", systemImage: "sparkles.rectangle.stack")
            } description: {
                Text("Choose a session or create a new one inside the current workspace.")
            } actions: {
                Button("New Session", action: createSession)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - ContentView Actions

private extension ContentView {
    func bootstrap() async {
        let defaultWorkspace = WorkspaceBootstrap.ensureDefaultWorkspace(in: modelContext)

        if selectedWorkspace == nil {
            selectedWorkspace = selectedSession?.workspace ?? defaultWorkspace
        }

        if selectedSession == nil {
            selectedSession = workspaceSessions.first
        }

        await modelManager.refreshInstalledModels()
        normalizeSelectedSessionModel()
        await setupIngestionManager()
    }

    func setupIngestionManager() async {
        do {
            let vectorStore = try VectorStore()
            try await vectorStore.open()
            ingestionManager = DocumentIngestionManager(
                vectorStore: vectorStore,
                modelManager: modelManager,
                modelContext: modelContext
            )
        } catch {
            ingestionManager = nil
        }
    }

    func createWorkspace() {
        let workspace = CourseWorkspace(name: "Course \(workspaces.count + 1)")
        modelContext.insert(workspace)
        selectedWorkspace = workspace
        selectedSession = nil
    }

    func createSession() {
        let workspace = selectedWorkspace ?? WorkspaceBootstrap.ensureDefaultWorkspace(in: modelContext)
        selectedWorkspace = workspace

        let resolvedModel = modelManager.resolveModelIdentifier(modelManager.currentModel)
        modelManager.currentModel = resolvedModel

        let session = ChatSession(
            modelIdentifier: resolvedModel,
            workspace: workspace,
            focusedDocument: workspaceDocuments.first
        )
        modelContext.insert(session)

        workspace.lastActivityAt = Date()
        selectedSession = session
    }

    func focusDocument(_ document: SourceDocument) {
        selectedSession?.focusedDocument = document
        document.lastUsedAt = Date()
        selectedWorkspace?.lastActivityAt = Date()
    }

    func deleteSession(_ session: ChatSession) {
        if selectedSession?.id == session.id {
            selectedSession = nil
        }
        modelContext.delete(session)
    }

    func syncSelectionFromWorkspace() {
        guard let selectedWorkspace else { return }

        if selectedSession?.workspace?.id != selectedWorkspace.id {
            selectedSession = workspaceSessions.first
        }
    }

    func syncSelectionFromSession() {
        if let selectedSession, selectedWorkspace?.id != selectedSession.workspace?.id {
            selectedWorkspace = selectedSession.workspace
        }
    }

    func normalizeSelectedSessionModel() {
        modelManager.currentModel = modelManager.resolveModelIdentifier(modelManager.currentModel)

        guard let selectedSession else { return }
        let resolvedModel = modelManager.resolveModelIdentifier(selectedSession.modelIdentifier)
        if selectedSession.modelIdentifier != resolvedModel {
            selectedSession.modelIdentifier = resolvedModel
        }
    }
}

// MARK: - Sidebar

private struct WorkspaceSidebarView: View {
    let workspaces: [CourseWorkspace]
    @Binding var selectedWorkspace: CourseWorkspace?
    @Binding var selectedSession: ChatSession?
    let sessions: [ChatSession]
    let documents: [SourceDocument]
    @Bindable var modelManager: ModelManager
    @Binding var targetLanguage: String
    let onCreateWorkspace: () -> Void
    let onCreateSession: () -> Void
    let onDeleteSession: (ChatSession) -> Void
    let onFocusDocument: (SourceDocument) -> Void

    var body: some View {
        ZStack {
            sidebarBackground

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SidebarHeaderBar(
                        modelManager: modelManager,
                        targetLanguage: $targetLanguage,
                        onCreateWorkspace: onCreateWorkspace,
                        onCreateSession: onCreateSession
                    )

                    SidebarPanelCard(title: "Workspace") {
                        WorkspacePickerRow(
                            workspaces: workspaces,
                            selectedWorkspace: $selectedWorkspace,
                            sessionCount: sessions.count,
                            documentCount: documents.count
                        )
                    }

                    if let selectedSession {
                        SidebarPanelCard(title: "Current Study Context") {
                            StudyContextCard(
                                session: selectedSession,
                                targetLanguage: targetLanguage
                            )
                        }
                    }

                    SidebarSectionHeader(title: "Sessions", trailingText: "\(sessions.count)")
                    if sessions.isEmpty {
                        SidebarEmptyState(
                            title: "No sessions yet",
                            subtitle: "Create a workspace-specific thread to start grounded study."
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(sessions) { session in
                                SessionCardView(
                                    session: session,
                                    isSelected: selectedSession?.id == session.id,
                                    onSelect: { selectedSession = session },
                                    onDelete: { onDeleteSession(session) }
                                )
                            }
                        }
                    }

                    SidebarSectionHeader(title: "Documents", trailingText: "\(documents.count)")
                    if documents.isEmpty {
                        SidebarEmptyState(
                            title: "No course material yet",
                            subtitle: "Drop a paper, notes, or code file into chat to build the workspace knowledge base."
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(documents) { document in
                                DocumentCardView(
                                    document: document,
                                    isFocused: selectedSession?.focusedDocument?.id == document.id,
                                    onFocus: { onFocusDocument(document) }
                                )
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private var sidebarBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.11, green: 0.14, blue: 0.21),
                Color(red: 0.07, green: 0.09, blue: 0.15),
                Color(red: 0.04, green: 0.05, blue: 0.09)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 210, height: 210)
                .blur(radius: 34)
                .offset(x: -60, y: -48)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.cyan.opacity(0.08))
                .frame(width: 180, height: 180)
                .blur(radius: 30)
                .offset(x: 56, y: 70)
        }
    }
}

private struct SidebarHeaderBar: View {
    @Bindable var modelManager: ModelManager
    @Binding var targetLanguage: String
    let onCreateWorkspace: () -> Void
    let onCreateSession: () -> Void

    var body: some View {
        SidebarPanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.26),
                                    Color.indigo.opacity(0.38)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                        }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("MaqkrsTutor")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Local course workspace")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Spacer(minLength: 12)

                    SidebarStatusPill(
                        title: modelManager.isOllamaAvailable ? "Ollama Ready" : "Offline",
                        tint: modelManager.isOllamaAvailable ? .green : .orange
                    )
                }

                HStack(spacing: 10) {
                    SidebarActionButton(
                        systemImage: "square.stack.badge.plus",
                        title: "Workspace",
                        action: onCreateWorkspace
                    )

                    SidebarActionButton(
                        systemImage: "plus.bubble.fill",
                        title: "Session",
                        prominence: .primary,
                        action: onCreateSession
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Model")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))

                    ModelSelectorView(
                        modelManager: modelManager,
                        selectedModelId: Binding(
                            get: { modelManager.currentModel },
                            set: { modelManager.currentModel = $0 }
                        )
                    )
                }

                Menu {
                    ForEach(SupportedLanguage.allCases) { language in
                        Button(language.rawValue) {
                            targetLanguage = language.rawValue
                        }
                    }
                } label: {
                    SidebarMenuLabel(
                        title: "Target Language",
                        value: targetLanguage,
                        systemImage: "globe"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct WorkspacePickerRow: View {
    let workspaces: [CourseWorkspace]
    @Binding var selectedWorkspace: CourseWorkspace?
    let sessionCount: Int
    let documentCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(workspaces) { workspace in
                    Button(workspace.name) {
                        selectedWorkspace = workspace
                    }
                }
            } label: {
                SidebarMenuLabel(
                    title: "Current Workspace",
                    value: selectedWorkspace?.name ?? "Select Workspace",
                    systemImage: "books.vertical.fill"
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                SidebarMetricBadge(
                    title: "\(sessionCount)",
                    systemImage: "bubble.left.and.bubble.right.fill",
                    tint: .cyan
                )

                SidebarMetricBadge(
                    title: "\(documentCount)",
                    systemImage: "doc.text.fill",
                    tint: .indigo
                )

                if let selectedWorkspace {
                    SidebarMetricBadge(
                        title: selectedWorkspace.lastActivityAt.formatted(.relative(presentation: .named)),
                        systemImage: "clock",
                        tint: .secondary
                    )
                }
            }
        }
    }
}

private struct StudyContextCard: View {
    @Bindable var session: ChatSession
    let targetLanguage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Default Action")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                ContextChip(
                    title: session.studyMode.displayName,
                    systemImage: session.studyMode.systemImage,
                    tint: .orange
                )
            }

            HStack(spacing: 8) {
                ContextChip(
                    title: targetLanguage,
                    systemImage: "globe",
                    tint: .purple
                )

                ContextChip(
                    title: session.focusedDocument?.readiness.displayName ?? "No document selected",
                    systemImage: session.focusedDocument?.readiness.systemImage ?? "doc.badge.questionmark",
                    tint: session.focusedDocument == nil ? .secondary : .green
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Focused Material")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                HStack(spacing: 10) {
                    Image(systemName: session.focusedDocument?.fileType.systemImage ?? "doc.badge.questionmark")
                        .foregroundStyle(.white.opacity(0.72))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.focusedDocument?.name ?? "Choose a document from the list")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                        if let focusedDocument = session.focusedDocument {
                            Text(focusedDocument.readinessSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.58))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

private struct SessionCardView: View {
    let session: ChatSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.cyan.opacity(0.92) : Color.white.opacity(0.12))
                        .frame(width: 4)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(session.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.trailing, 30)

                        HStack(spacing: 8) {
                            ContextChip(
                                title: session.studyMode.displayName,
                                systemImage: session.studyMode.systemImage,
                                tint: .orange
                            )

                            Spacer(minLength: 0)

                            Text(session.lastActivityAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.56))
                        }

                        if let focusedDocument = session.focusedDocument {
                            Label(focusedDocument.name, systemImage: focusedDocument.fileType.systemImage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                        } else {
                            Label("No focused material", systemImage: "doc.badge.questionmark")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.52))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .padding(8)
                    .background(Color.black.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .padding(10)
        }
        .modifier(SidebarCardSurface(isSelected: isSelected))
        .accessibilityIdentifier("session-link")
    }
}

private struct DocumentCardView: View {
    let document: SourceDocument
    let isFocused: Bool
    let onFocus: () -> Void

    var body: some View {
        Button(action: onFocus) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(isFocused ? 0.42 : 0.28),
                                Color.cyan.opacity(isFocused ? 0.34 : 0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: document.fileType.systemImage)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        SidebarMetricBadge(
                            title: document.readiness.displayName,
                            systemImage: document.readiness.systemImage,
                            tint: document.readiness == .deferred ? .secondary : .cyan
                        )

                        SidebarMetricBadge(
                            title: document.ingestedAt.formatted(.relative(presentation: .named)),
                            systemImage: "clock",
                            tint: .secondary
                        )
                    }

                    Text(document.readinessSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer()

                if isFocused {
                    ContextChip(
                        title: "Focused",
                        systemImage: "scope",
                        tint: .green
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .modifier(SidebarCardSurface(isSelected: isFocused))
    }
}

private struct SidebarPanelCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            content
        }
        .padding(14)
        .modifier(SidebarCardSurface(isSelected: false))
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let trailingText: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.74))
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()
            Text(trailingText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
        }
        .padding(.horizontal, 4)
    }
}

private struct SidebarEmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(14)
        .modifier(SidebarCardSurface(isSelected: false))
    }
}

private struct ContextChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint == .secondary ? Color.white.opacity(0.08) : tint.opacity(0.18))
            )
            .foregroundStyle(tint == .secondary ? Color.white.opacity(0.75) : tint)
    }
}

private struct SidebarCardSurface: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        content
            .background(
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isSelected ? 0.12 : 0.08),
                                        Color.white.opacity(isSelected ? 0.04 : 0.025)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        shape
                            .strokeBorder(
                                Color.white.opacity(isSelected ? 0.14 : 0.045),
                                lineWidth: isSelected ? 0.9 : 0.7
                            )
                    }
            )
            .clipShape(shape)
            .shadow(
                color: .black.opacity(isSelected ? 0.18 : 0.09),
                radius: isSelected ? 18 : 10,
                y: 8
            )
    }
}

private struct SidebarStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

private struct SidebarActionButton: View {
    enum Prominence {
        case standard
        case primary
    }

    let systemImage: String
    let title: String
    var prominence: Prominence = .standard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(.white.opacity(prominence == .primary ? 0.96 : 0.82))
                .background(backgroundShape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(prominence == .primary ? "new-session-button" : "")
    }

    @ViewBuilder
    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                prominence == .primary
                ? LinearGradient(
                    colors: [Color.cyan.opacity(0.34), Color.indigo.opacity(0.42)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                : LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(prominence == .primary ? 0.16 : 0.06))
            }
    }
}

private struct SidebarMetricBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(backgroundTint, in: Capsule())
            .foregroundStyle(foregroundTint)
    }

    private var backgroundTint: Color {
        tint == .secondary ? Color.white.opacity(0.07) : tint.opacity(0.16)
    }

    private var foregroundTint: Color {
        tint == .secondary ? Color.white.opacity(0.62) : tint
    }
}

private struct SidebarMenuLabel: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.56))
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.44))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
