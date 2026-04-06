//
//  DocumentIngestionManager.swift
//  MaqkrsTutor
//
//  Core/RAG — Phase 6 Document Ingestion Pipeline
//  Created April 4, 2026
//
//  Full 4-Stage Pipeline:
//  Stage A: Security-Scoped File Access (bypass macOS sandbox)
//  Stage B: @PythonActor chunking via semantic_chunker.py / tree_sitter_ast.py
//  Stage C: Ollama nomic-embed-text:v1.5 embedding via ModelManager.embed()
//  Stage D: VectorStore.insert() handoff into sqlite-vec
//
//  Media Slicing:
//  - .mp4 → AVFoundation 60s chunks → transcript → embed
//  - .mp3/.m4a → AVFoundation 30s chunks → transcript → embed
//  - .pdf → PDFKit text extraction → chunk → embed
//  - Source code → tree_sitter_ast.py → chunk → embed
//
//  Constraints:
//  - PythonKit called ONLY on @PythonActor — GIL safety enforced at compile time
//  - All file access uses security-scoped bookmarks
//  - ingestedFiles array updated on MainActor after each successful insert
//

import Foundation
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
import Observation
import SwiftData
import Vision
import AppKit

// MARK: - Ingested File Record

/// Metadata for a successfully ingested document, shown in the sidebar Knowledge Base.
struct IngestedFileRecord: Identifiable, Sendable {
    let id = UUID()
    let documentID: UUID
    let name: String
    let chunkCount: Int
    let ingestedAt: Date
    let fileType: SourceDocumentType
}

// MARK: - Text Chunk (internal)

/// An intermediate text chunk produced by the chunking stage, before embedding.
struct TextChunk: Sendable {
    let text: String
    let index: Int
    let type: String  // "text", "function", "class", "method"
    let sectionTitle: String?
    let pageLabel: String?
}

enum DirectDocumentConfig {
    // Conservative defaults to keep Gemma 4 latency/thermals stable on-device.
    static let maxPDFPagesForProcessing = 24
    static let maxCharactersForDirectContext = 60_000
    static let maxChunksForEmbedding = 140

    // Disable heavy embedding ingestion for these file classes by default.
    static let embedPDFByDefault = false
    static let embedPlainTextByDefault = false
    static let embedCodeByDefault = false
}

enum DocumentIngestionMode: String, CaseIterable, Identifiable, Sendable {
    case directContext
    case ragIndex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .directContext:
            return "Direct Context"
        case .ragIndex:
            return "RAG Index"
        }
    }

    var systemImage: String {
        switch self {
        case .directContext:
            return "doc.text"
        case .ragIndex:
            return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Ingestion Error

enum IngestionError: LocalizedError {
    case sandboxAccessDenied(URL)
    case unsupportedFileType(String)
    case pdfExtractionFailed
    case pythonChunkingFailed(String)
    case embeddingFailed(String)
    case avExportFailed
    case transcriptionUnavailable

    var errorDescription: String? {
        switch self {
        case .sandboxAccessDenied(let url):
            return "Access denied to: \(url.lastPathComponent). Ensure the app has permission."
        case .unsupportedFileType(let ext):
            return "File type '\(ext)' is not yet supported for ingestion."
        case .pdfExtractionFailed:
            return "Failed to extract text from the PDF. The file may be protected or image-only."
        case .pythonChunkingFailed(let msg):
            return "Python chunker error: \(msg)"
        case .embeddingFailed(let msg):
            return "Embedding failed: \(msg)"
        case .avExportFailed:
            return "AVFoundation failed to slice the media file."
        case .transcriptionUnavailable:
            return "On-device speech transcription is not available on this OS version."
        }
    }
}

// MARK: - Document Ingestion Manager

/// Manages the full document ingestion pipeline for the RAG knowledge base.
/// Inject into the SwiftUI environment via `.environment(ingestionManager)`.
///
/// Usage:
/// ```swift
/// @Environment(DocumentIngestionManager.self) var ingestionManager
/// // From a drop handler:
/// try await ingestionManager.ingest(providers: providers)
/// ```
@Observable
@MainActor
final class DocumentIngestionManager {

    // MARK: - Published State (RAG Transparency UI)

    /// Files that have been successfully embedded and inserted into VectorStore.
    /// Shown in the ContentView sidebar "Active Knowledge Base" section.
    var ingestedFiles: [IngestedFileRecord] = []

    /// 0.0–1.0 progress during active ingestion, or nil when idle.
    var ingestionProgress: Double? = nil

    /// Human-readable status message shown during ingestion.
    var statusMessage: String = ""

    /// Files currently staged (dropped but not yet ingested).
    var stagedAttachments: [StagedAttachment] = []

    // MARK: - Dependencies

    /// Publicly accessible for RAG queries from ChatView.
    /// The VectorStore is opened during initialization.
    let vectorStore: VectorStore
    private let modelManager: ModelManager
    private let modelContext: ModelContext

    // MARK: - Init

    init(vectorStore: VectorStore, modelManager: ModelManager, modelContext: ModelContext) {
        self.vectorStore = vectorStore
        self.modelManager = modelManager
        self.modelContext = modelContext
    }

    // MARK: - RAG Query

    /// Retrieves the most relevant document chunks for a user query.
    /// Uses the shared modelManager to embed the query, then queries VectorStore.
    ///
    /// - Parameters:
    ///   - query: The user's natural language query
    ///   - k: Number of chunks to retrieve (default 5, max 20)
    /// - Returns: Array of relevant chunks, or empty if no knowledge base or error
    func retrieveContext(
        for query: String,
        scope: RetrievalScope?,
        k: Int = 5
    ) async -> [RetrievalResult] {
        do {
            let queryEmbedding = try await modelManager.embed(text: query)
            return try await vectorStore.retrieveNearest(
                queryEmbedding: queryEmbedding,
                k: k,
                scope: scope
            )
        } catch {
            print("RAG query failed: \(error)")
            return []
        }
    }

    func retrieveOrderedContext(for document: SourceDocument) async -> [RetrievalResult] {
        do {
            return try await vectorStore.retrieveDocumentChunks(documentID: document.id)
        } catch {
            print("Document retrieval failed: \(error)")
            return []
        }
    }

    // MARK: - Ingest from NSItemProvider (onDrop)

    /// Entry point for SwiftUI `.onDrop` handler.
    /// Resolves each `NSItemProvider` to a security-scoped URL, then runs the pipeline.
    @discardableResult
    func ingest(
        providers: [NSItemProvider],
        mode: DocumentIngestionMode = .directContext,
        into workspace: CourseWorkspace? = nil
    ) async -> [SourceDocument] {
        let targetWorkspace = workspace ?? WorkspaceBootstrap.ensureDefaultWorkspace(in: modelContext)
        ingestionProgress = 0.0
        let total = Double(providers.count)
        var ingestedDocuments: [SourceDocument] = []

        for (index, provider) in providers.enumerated() {
            statusMessage = "Resolving file \(index + 1) of Int(total)…"

            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }

            do {
                let url = try await resolveURL(from: provider)
                if let document = try await processFile(
                    url: url,
                    mode: mode,
                    workspace: targetWorkspace
                ) {
                    ingestedDocuments.append(document)
                }
                ingestionProgress = Double(index + 1) / total
            } catch {
                statusMessage = "❌ \(error.localizedDescription)"
            }
        }

        ingestionProgress = nil
        statusMessage = ""
        return ingestedDocuments
    }

    /// Entry point for `.fileImporter` result.
    @discardableResult
    func ingest(
        urls: [URL],
        mode: DocumentIngestionMode = .directContext,
        into workspace: CourseWorkspace? = nil
    ) async -> [SourceDocument] {
        let targetWorkspace = workspace ?? WorkspaceBootstrap.ensureDefaultWorkspace(in: modelContext)
        ingestionProgress = 0.0
        let total = Double(urls.count)
        var ingestedDocuments: [SourceDocument] = []

        for (index, url) in urls.enumerated() {
            statusMessage = "Ingesting \(url.lastPathComponent)…"
            do {
                if let document = try await processFile(
                    url: url,
                    mode: mode,
                    workspace: targetWorkspace
                ) {
                    ingestedDocuments.append(document)
                }
                ingestionProgress = Double(index + 1) / total
            } catch {
                statusMessage = "❌ \(error.localizedDescription)"
            }
        }

        ingestionProgress = nil
        statusMessage = ""
        return ingestedDocuments
    }

    // MARK: - URL Resolution

    private func resolveURL(from provider: NSItemProvider) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: IngestionError.unsupportedFileType("unknown"))
                }
            }
        }
    }

    // MARK: - Main File Processor

    /// Routes a file URL to the appropriate extraction strategy by UTType.
    private func processFile(
        url: URL,
        mode: DocumentIngestionMode,
        workspace: CourseWorkspace
    ) async throws -> SourceDocument? {
        // Acquire security-scoped resource access (sandbox bypass)
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        let utType = UTType(filenameExtension: url.pathExtension.lowercased())
        let fileName = url.lastPathComponent

        statusMessage = "Processing \(fileName)…"
        let fileType = fileTypeFor(url: url)

        guard fileType.isPrimaryStudyDocument else {
            throw IngestionError.unsupportedFileType(url.pathExtension.lowercased())
        }

        let chunks: [TextChunk]
        var directContextText: String?
        var directContextTruncated = false
        var totalPageCount: Int?
        var processedPageCount: Int?

        if utType?.conforms(to: .pdf) == true {
            // PDF → bounded extraction for direct prompting on-device.
            let extraction = try await extractPDFWithLimits(url: url)
            chunks = extraction.chunks
            directContextText = extraction.directContextText
            directContextTruncated = extraction.wasTruncated
            totalPageCount = extraction.totalPageCount
            processedPageCount = extraction.processedPageCount
        } else if isSourceCode(url: url) {
            // Source code → @PythonActor tree_sitter_ast.py
            chunks = try await chunkSourceCode(url: url)
            directContextText = chunks.map(\.text).joined(separator: "\n\n")
        } else {
            // Plain text / markdown → @PythonActor semantic_chunker.py
            guard let rawText = try? String(contentsOf: url, encoding: .utf8) else {
                throw IngestionError.pdfExtractionFailed
            }
            chunks = try await chunkText(rawText, sourceFile: fileName)
            directContextText = rawText
        }

        if let context = directContextText {
            let capped = String(context.prefix(DirectDocumentConfig.maxCharactersForDirectContext))
            directContextTruncated = directContextTruncated || capped.count < context.count
            directContextText = capped
        }

        guard !chunks.isEmpty else {
            statusMessage = "⚠️ No content extracted from \(fileName)"
            return nil
        }

        let existingDocument = sourceDocument(named: fileName, in: workspace)
        let documentID = existingDocument?.id ?? UUID()

        let shouldEmbed = shouldEmbedFor(fileType: fileType, mode: mode)
        var embeddedCount = 0

        if shouldEmbed {
            let cappedChunks = Array(chunks.prefix(DirectDocumentConfig.maxChunksForEmbedding))
            statusMessage = "Embedding \(cappedChunks.count) chunks from \(fileName)…"
            let embedded = try await embedChunks(
                chunks: cappedChunks,
                sourceFile: fileName,
                workspaceID: workspace.id,
                documentID: documentID
            )

            statusMessage = "Inserting into VectorStore…"
            if let existingDocument {
                try await vectorStore.deleteChunks(forDocumentID: existingDocument.id)
            }
            try await vectorStore.insert(chunks: embedded)
            embeddedCount = embedded.count
        } else {
            statusMessage = "Direct document mode enabled for \(fileName) (RAG embeddings skipped)."
            if let existingDocument {
                try await vectorStore.deleteChunks(forDocumentID: existingDocument.id)
            }
            embeddedCount = 0
        }

        let document = existingDocument ?? SourceDocument(
            id: documentID,
            name: fileName,
            sourceFile: fileName,
            fileType: fileType,
            chunkCount: embeddedCount,
            directContextText: directContextText,
            directContextTruncated: directContextTruncated,
            totalPageCount: totalPageCount,
            processedPageCount: processedPageCount,
            workspace: workspace
        )

        if existingDocument == nil {
            modelContext.insert(document)
        }

        document.name = fileName
        document.sourceFile = fileName
        document.fileType = fileType
        document.chunkCount = embeddedCount
        document.directContextText = directContextText
        document.directContextTruncated = directContextTruncated
        document.totalPageCount = totalPageCount
        document.processedPageCount = processedPageCount
        document.ingestedAt = Date()
        document.lastUsedAt = Date()
        document.workspace = workspace

        workspace.lastActivityAt = Date()

        syncIngestedFiles(for: workspace)

        if directContextTruncated {
            statusMessage = "✅ \(fileName) — direct context prepared (truncated for on-device limits)"
        } else if shouldEmbed {
            statusMessage = "✅ \(fileName) — \(embeddedCount) chunks indexed"
        } else {
            statusMessage = "✅ \(fileName) — direct context prepared"
        }

        return document
    }

    // MARK: - Stage B: PDF Extraction

    private struct PDFExtractionResult {
        let chunks: [TextChunk]
        let directContextText: String
        let totalPageCount: Int
        let processedPageCount: Int
        let wasTruncated: Bool
    }

    private func extractPDFWithLimits(url: URL) async throws -> PDFExtractionResult {
        guard let document = PDFDocument(url: url) else {
            throw IngestionError.pdfExtractionFailed
        }

        let totalPageCount = document.pageCount
        let processedPageCount = min(totalPageCount, DirectDocumentConfig.maxPDFPagesForProcessing)
        var chunks: [TextChunk] = []
        var pageContexts: [String] = []

        for i in 0..<processedPageCount {
            guard let page = document.page(at: i) else { continue }

            let extracted = extractTextFromPDFPage(page)
            guard !extracted.isEmpty else { continue }

            pageContexts.append("[Page \(i + 1)]\n\(extracted)")

            let pageChunks = splitIntoChunks(text: extracted, chunkSize: 500, overlap: 50)
            chunks += pageChunks.enumerated().map { idx, chunkText in
                TextChunk(
                    text: chunkText,
                    index: chunks.count + idx,
                    type: "text",
                    sectionTitle: "PDF",
                    pageLabel: "Page \(i + 1)"
                )
            }
        }

        let directContextText = pageContexts.joined(separator: "\n\n")
        let wasTruncated = totalPageCount > processedPageCount

        return PDFExtractionResult(
            chunks: chunks,
            directContextText: directContextText,
            totalPageCount: totalPageCount,
            processedPageCount: processedPageCount,
            wasTruncated: wasTruncated
        )
    }

    private func extractTextFromPDFPage(_ page: PDFPage) -> String {
        let directText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !directText.isEmpty {
            return directText
        }

        return ocrTextFromPDFPage(page)
    }

    private func ocrTextFromPDFPage(_ page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        let maxDimension = max(bounds.width, bounds.height)
        let renderWidth = max(1400, min(2200, Int(maxDimension * 1.8)))
        let imageSize = NSSize(width: renderWidth, height: renderWidth)

        let image = page.thumbnail(of: imageSize, for: .mediaBox)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    // MARK: - Stage B: AVFoundation Media Slicing

    /// Slices audio/video into fixed-duration chunks using AVFoundation.
    /// For video: 60s chunks. For audio: 30s chunks.
    /// NOTE: Transcription requires on-device Speech framework (macOS 13+).
    private func processAVMedia(url: URL, chunkDuration: TimeInterval, type: String) async throws -> [TextChunk] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let totalSeconds = duration.seconds

        var chunkURLs: [URL] = []
        var startTime: TimeInterval = 0
        var sliceIndex = 0

        while startTime < totalSeconds {
            let endTime = min(startTime + chunkDuration, totalSeconds)
            let timeRange = CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: 600),
                end: CMTime(seconds: endTime, preferredTimescale: 600)
            )

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_slice\(sliceIndex).m4a")

            // Remove any existing temp file
            try? FileManager.default.removeItem(at: outputURL)

            guard let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw IngestionError.avExportFailed
            }

            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a
            exporter.timeRange = timeRange
            await exporter.export()

            guard exporter.status == .completed else {
                throw IngestionError.avExportFailed
            }

            chunkURLs.append(outputURL)
            sliceIndex += 1
            startTime = endTime
        }

        // Transcription placeholder — integrate Apple's Speech framework or Whisper-CoreML in Phase 7
        // For now, return descriptive placeholder chunks acknowledging the media
        let placeholders = chunkURLs.enumerated().map { idx, chunkURL in
            TextChunk(
                text: "[Audio segment \(idx + 1) from '\(url.lastPathComponent)' — duration: ~\(Int(chunkDuration))s. Transcription pipeline pending Whisper-CoreML integration in Phase 7.]",
                index: idx,
                type: type,
                sectionTitle: type.capitalized,
                pageLabel: nil
            )
        }

        // Clean up temp files
        chunkURLs.forEach { try? FileManager.default.removeItem(at: $0) }

        return placeholders
    }

    // MARK: - Stage B: Source Code Chunking (@PythonActor)

    @PythonActor
    private func chunkSourceCode(url: URL) throws -> [TextChunk] {
        // PythonKit is safe here — @PythonActor enforces serial GIL access
        // When PythonKit SPM is integrated:
        // let ast = Python.import("tree_sitter_ast")
        // let result = ast.parse_file(url.path)
        // return result.map { TextChunk(text: $0.text, index: $0.index, type: $0.type) }

        // Fallback: read file as plain text until PythonKit is integrated
        guard let code = try? String(contentsOf: url, encoding: .utf8) else {
            throw IngestionError.pythonChunkingFailed("Could not read source file: \(url.lastPathComponent)")
        }
        let rawChunks = splitIntoChunks(text: code, chunkSize: 300, overlap: 30)
        return rawChunks.enumerated().map { idx, text in
            TextChunk(
                text: text,
                index: idx,
                type: "code",
                sectionTitle: url.lastPathComponent,
                pageLabel: nil
            )
        }
    }

    // MARK: - Stage B: Text Chunking (@PythonActor)

    @PythonActor
    private func chunkText(_ text: String, sourceFile: String) throws -> [TextChunk] {
        // PythonKit is safe here — @PythonActor enforces serial GIL access
        // When PythonKit SPM is integrated:
        // let chunker = Python.import("semantic_chunker")
        // let result = chunker.chunk(text, sourceFile)
        // return result.map { TextChunk(text: $0.text, index: $0.index, type: "text") }

        // Fallback: naive sliding window chunking until PythonKit is integrated
        let rawChunks = splitIntoChunks(text: text, chunkSize: 500, overlap: 50)
        return rawChunks.enumerated().map { idx, chunkText in
            TextChunk(
                text: chunkText,
                index: idx,
                type: "text",
                sectionTitle: sourceFile,
                pageLabel: nil
            )
        }
    }

    // MARK: - Stage C: Embedding via ModelManager

    private func embedChunks(
        chunks: [TextChunk],
        sourceFile: String,
        workspaceID: UUID,
        documentID: UUID
    ) async throws -> [EmbeddingChunk] {
        var results: [EmbeddingChunk] = []

        for chunk in chunks {
            let vector = try await modelManager.embed(text: chunk.text)
            results.append(EmbeddingChunk(
                text: chunk.text,
                sourceFile: sourceFile,
                workspaceID: workspaceID,
                documentID: documentID,
                chunkID: UUID(),
                chunkIndex: chunk.index,
                chunkType: chunk.type,
                sectionTitle: chunk.sectionTitle,
                pageLabel: chunk.pageLabel,
                embedding: vector
            ))
        }

        return results
    }

    // MARK: - Utilities

    /// Naive sliding-window text splitter used as fallback before PythonKit.
    /// `nonisolated` so it can be called from @PythonActor-isolated functions.
    private nonisolated func splitIntoChunks(text: String, chunkSize: Int, overlap: Int) -> [String] {
        guard !text.isEmpty else { return [] }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))

            let nextStart = text.index(start, offsetBy: chunkSize - overlap, limitedBy: text.endIndex) ?? text.endIndex
            if nextStart >= text.endIndex { break }
            start = nextStart
        }

        return chunks
    }

    private func isSourceCode(url: URL) -> Bool {
        let codeExtensions = ["swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt", "rb"]
        return codeExtensions.contains(url.pathExtension.lowercased())
    }

    private func shouldEmbedFor(fileType: SourceDocumentType, mode: DocumentIngestionMode) -> Bool {
        if mode == .ragIndex {
            return true
        }

        switch fileType {
        case .pdf:
            return DirectDocumentConfig.embedPDFByDefault
        case .text:
            return DirectDocumentConfig.embedPlainTextByDefault
        case .code:
            return DirectDocumentConfig.embedCodeByDefault
        case .audio, .video, .image, .unknown:
            return false
        }
    }

    private func fileTypeFor(url: URL) -> SourceDocumentType {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if isSourceCode(url: url) { return .code }
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return .image }
        if ["mp3", "m4a", "wav", "aac"].contains(ext) { return .audio }
        if ["mp4", "mov", "m4v"].contains(ext) { return .video }
        if ["txt", "md", "markdown"].contains(ext) { return .text }
        return .unknown
    }

    private func sourceDocument(named fileName: String, in workspace: CourseWorkspace) -> SourceDocument? {
        let descriptor = FetchDescriptor<SourceDocument>()
        let documents = (try? modelContext.fetch(descriptor)) ?? []
        return documents.first {
            $0.workspace?.id == workspace.id && ($0.sourceFile == fileName || $0.name == fileName)
        }
    }

    private func syncIngestedFiles(for workspace: CourseWorkspace) {
        let descriptor = FetchDescriptor<SourceDocument>(
            sortBy: [SortDescriptor(\.ingestedAt, order: .reverse)]
        )
        let documents = ((try? modelContext.fetch(descriptor)) ?? []).filter {
            $0.workspace?.id == workspace.id && $0.isPrimaryStudyMaterial
        }

        ingestedFiles = documents.map { document in
            IngestedFileRecord(
                documentID: document.id,
                name: document.name,
                chunkCount: document.chunkCount,
                ingestedAt: document.ingestedAt,
                fileType: document.fileType
            )
        }
    }
}

// MARK: - Staged Attachment

/// A file staged for ingestion, shown as a chip above the input field in ChatView.
struct StagedAttachment: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let url: URL

    enum AttachmentType: Sendable {
        case pdf, code, image, audio, video, text, unknown

        nonisolated var systemImage: String {
            switch self {
            case .pdf:     "doc.richtext.fill"
            case .code:    "chevron.left.forwardslash.chevron.right"
            case .image:   "photo.fill"
            case .audio:   "waveform"
            case .video:   "film.fill"
            case .text:    "doc.text.fill"
            case .unknown: "doc.fill"
            }
        }

        nonisolated var isStudySource: Bool {
            switch self {
            case .pdf, .code, .text:
                return true
            case .image, .audio, .video, .unknown:
                return false
            }
        }

        nonisolated var isSupportedUpload: Bool {
            switch self {
            case .pdf, .code, .text, .image:
                return true
            case .audio, .video, .unknown:
                return false
            }
        }
    }

    let type: AttachmentType

    nonisolated var isStudySource: Bool {
        type.isStudySource
    }

    nonisolated var isSupportedUpload: Bool {
        type.isSupportedUpload
    }

    nonisolated init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { self.type = .pdf }
        else if ["swift", "py", "js", "ts", "go", "rs", "c", "cpp", "java"].contains(ext) { self.type = .code }
        else if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { self.type = .image }
        else if ["mp3", "m4a", "wav", "aac"].contains(ext) { self.type = .audio }
        else if ["mp4", "mov", "m4v"].contains(ext) { self.type = .video }
        else if ["txt", "md"].contains(ext) { self.type = .text }
        else { self.type = .unknown }
    }
}
