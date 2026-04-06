//
//  VectorStore.swift
//  MaqkrsTutor
//
//  Core/RAG — sqlite-vec vector storage engine
//  Architecture: @Planner (Claude Opus 4.6)
//  Implementation: @Coder (Fixed April 4, 2026)
//
//  Constraints (from GEMINI.md):
//  - sqlite-vec via C-bindings, local-only
//  - Initialize with try SQLiteVec.initialize()
//  - Virtual table: vec_items USING vec0(embedding float[768])
//  - No cloud vector databases
//
//  SQLiteVec API Reference (jkrukowski/SQLiteVec):
//  - Database is an actor
//  - Database.Location: .inMemory, .temporary, .uri(String)
//  - execute(_:params:) throws -> Int  (synchronous, actor-isolated)
//  - query(_:params:) throws -> [[String: any Sendable]]  (synchronous, actor-isolated)
//  - transaction(_:block:) async throws  (built-in BEGIN/COMMIT/ROLLBACK)
//  - lastInsertRowId: Int  (actor-isolated property)
//

import Foundation
import SQLiteVec

// MARK: - Vector Store Configuration

/// Configuration constants for the vector storage engine.
/// Marked `Sendable` and all properties are `nonisolated` — safe to access from any isolation context.
enum VectorStoreConfig: Sendable {
    /// Embedding dimension (768 for typical sentence-transformer models).
    nonisolated static let embeddingDimension: Int = 768

    /// SQLite database filename for vector storage.
    nonisolated static let databaseName: String = "maqkrs_vectors.db"

    /// SQL to create the vec0 virtual table for KNN retrieval.
    nonisolated static let createVirtualTableSQL: String = """
        CREATE VIRTUAL TABLE IF NOT EXISTS vec_items
        USING vec0(embedding float[\(embeddingDimension)])
        """

    /// SQL to create the metadata table linked to vector rowids.
    nonisolated static let createMetadataTableSQL: String = """
        CREATE TABLE IF NOT EXISTS vec_metadata (
            id INTEGER PRIMARY KEY,
            workspace_id TEXT,
            document_id TEXT,
            chunk_uuid TEXT,
            source_file TEXT NOT NULL,
            chunk_text TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            chunk_type TEXT NOT NULL DEFAULT 'text',
            section_title TEXT,
            page_label TEXT,
            created_at REAL NOT NULL DEFAULT (unixepoch('now')),
            FOREIGN KEY (id) REFERENCES vec_items(rowid)
        )
        """

    nonisolated static let createWorkspaceIndexSQL: String = """
        CREATE INDEX IF NOT EXISTS idx_vec_metadata_workspace
        ON vec_metadata(workspace_id)
        """

    nonisolated static let createDocumentIndexSQL: String = """
        CREATE INDEX IF NOT EXISTS idx_vec_metadata_document
        ON vec_metadata(document_id, chunk_index)
        """

    /// Default K value for K-Nearest Neighbors retrieval.
    nonisolated static let defaultKnnK: Int = 5

    /// Maximum K value to prevent excessive memory usage on M4 Max.
    nonisolated static let maxKnnK: Int = 20
}

// MARK: - Embedding Chunk

/// A text chunk paired with its embedding vector, ready for storage.
struct EmbeddingChunk: Sendable {
    /// The original text content of the chunk.
    let text: String

    /// The source file path this chunk was extracted from.
    let sourceFile: String

    /// Workspace scope for retrieval.
    let workspaceID: UUID?

    /// Document scope for retrieval.
    let documentID: UUID?

    /// Stable chunk identifier for provenance UI.
    let chunkID: UUID

    /// The chunk's position index within its source document.
    let chunkIndex: Int

    /// The type of chunk: "text", "function", "class", "method".
    let chunkType: String

    /// Optional semantic section title for provenance.
    let sectionTitle: String?

    /// Optional page label when available (for example "Page 3").
    let pageLabel: String?

    /// The embedding vector (must have exactly `embeddingDimension` floats).
    let embedding: [Float]
}

// MARK: - Retrieval Scope

enum RetrievalScope: Sendable, Equatable {
    case document(UUID)
    case workspace(UUID)
    case hybrid(documentID: UUID?, workspaceID: UUID)
}

// MARK: - Retrieval Result

/// A single result from KNN vector similarity search.
struct RetrievalResult: Sendable {
    /// The matched text content.
    let text: String

    /// Source file path of the matched chunk.
    let sourceFile: String

    /// Workspace and document identifiers used for scoping.
    let workspaceID: UUID?
    let documentID: UUID?

    /// Stable chunk identifier for provenance tracking.
    let chunkID: UUID?

    /// Cosine distance (lower = more similar).
    let distance: Float

    /// The chunk type (text, function, class, method).
    let chunkType: String

    /// Position within the source document.
    let chunkIndex: Int

    /// Optional semantic metadata for UI citations.
    let sectionTitle: String?
    let pageLabel: String?

    nonisolated var id: String {
        if let chunkID {
            return chunkID.uuidString
        }
        return "\(sourceFile)-\(chunkIndex)"
    }
}

// MARK: - Vector Store

/// The core vector storage engine using sqlite-vec for local embedding storage
/// and KNN retrieval. All operations are local-only per GEMINI.md zero-cloud policy.
///
/// Both `VectorStore` and `Database` (from SQLiteVec) are actors.
/// All calls from VectorStore → Database cross actor boundaries and require `await`.
///
/// - Important: Call methods from `Task.detached` blocks to protect the Main Actor.
actor VectorStore {

    /// The SQLiteVec database instance (also an actor).
    private var database: Database?

    /// Path to the SQLite database file.
    private let databasePath: URL

    // MARK: - Initialization

    /// Initializes the vector store, preparing the database path and loading sqlite-vec.
    ///
    /// Per GEMINI.md: Initialize with `try SQLiteVec.initialize()` before any operations.
    ///
    /// - Parameter directory: The directory to store the database in.
    ///   Defaults to the app's Application Support directory.
    /// - Throws: If sqlite-vec initialization fails.
    init(directory: URL? = nil) throws {
        let appSupportDirectory: URL
        if let directory {
            appSupportDirectory = directory
        } else if let discovered = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            appSupportDirectory = discovered
        } else {
            throw VectorStoreError.databaseInitializationFailed(
                underlying: CocoaError(.fileNoSuchFile)
            )
        }

        let storageDir = appSupportDirectory.appendingPathComponent("MaqkrsTutor", isDirectory: true)

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: storageDir,
            withIntermediateDirectories: true
        )

        self.databasePath = storageDir.appendingPathComponent(
            VectorStoreConfig.databaseName
        )

        // Initialize the sqlite-vec extension (C-bindings) - REQUIRED before any DB operations
        try SQLiteVec.initialize()
    }

    /// Opens the database connection and creates tables if needed.
    /// Call this once before any database operations.
    func open() async throws {
        // Database.Location only has: .inMemory, .temporary, .uri(String)
        database = try Database(.uri(databasePath.path))
        try await createTablesIfNeeded()
        try await migrateMetadataTableIfNeeded()
        try await createIndexesIfNeeded()
    }

    // MARK: - Table Creation

    /// Creates the vec0 virtual table and metadata table if they don't exist.
    private func createTablesIfNeeded() async throws {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        // Cross-actor calls to Database actor require `await`
        try await db.execute(VectorStoreConfig.createVirtualTableSQL)
        try await db.execute(VectorStoreConfig.createMetadataTableSQL)
    }

    private func migrateMetadataTableIfNeeded() async throws {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        let columns = try await db.query("PRAGMA table_info(vec_metadata)")
        let existing = Set(columns.compactMap { $0["name"] as? String })

        let migrations: [(String, String)] = [
            ("workspace_id", "ALTER TABLE vec_metadata ADD COLUMN workspace_id TEXT"),
            ("document_id", "ALTER TABLE vec_metadata ADD COLUMN document_id TEXT"),
            ("chunk_uuid", "ALTER TABLE vec_metadata ADD COLUMN chunk_uuid TEXT"),
            ("section_title", "ALTER TABLE vec_metadata ADD COLUMN section_title TEXT"),
            ("page_label", "ALTER TABLE vec_metadata ADD COLUMN page_label TEXT")
        ]

        for (column, sql) in migrations where !existing.contains(column) {
            try await db.execute(sql)
        }
    }

    private func createIndexesIfNeeded() async throws {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        try await db.execute(VectorStoreConfig.createWorkspaceIndexSQL)
        try await db.execute(VectorStoreConfig.createDocumentIndexSQL)
    }

    // MARK: - Insert Embeddings

    /// Inserts a batch of embedding chunks into the vector store.
    ///
    /// Uses `Database.transaction()` for atomic batch inserts.
    ///
    /// - Parameter chunks: Array of `EmbeddingChunk` objects to store.
    /// - Throws: If any embedding dimension doesn't match `embeddingDimension`,
    ///   or if the database insert fails.
    func insert(chunks: [EmbeddingChunk]) async throws {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        // Validate all embeddings have correct dimension before starting transaction
        for chunk in chunks {
            guard chunk.embedding.count == VectorStoreConfig.embeddingDimension else {
                throw VectorStoreError.dimensionMismatch(
                    expected: VectorStoreConfig.embeddingDimension,
                    actual: chunk.embedding.count
                )
            }
        }

        // Database.transaction() handles BEGIN/COMMIT/ROLLBACK internally
        try await db.transaction {
            for chunk in chunks {
                // Insert into vec_items (vector virtual table)
                try await db.execute(
                    "INSERT INTO vec_items(embedding) VALUES (?)",
                    params: [chunk.embedding]
                )

                // Get the rowid of the just-inserted vector (cross-actor property access)
                let rowid = await db.lastInsertRowId

                // Insert metadata linked to the vector rowid
                let metadataParams: [any Sendable] = [
                    rowid,
                    chunk.workspaceID?.uuidString,
                    chunk.documentID?.uuidString,
                    chunk.chunkID.uuidString,
                    chunk.sourceFile,
                    chunk.text,
                    chunk.chunkIndex,
                    chunk.chunkType,
                    chunk.sectionTitle,
                    chunk.pageLabel
                ]
                try await db.execute(
                    """
                    INSERT INTO vec_metadata(
                        id, workspace_id, document_id, chunk_uuid, source_file,
                        chunk_text, chunk_index, chunk_type, section_title, page_label
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    params: metadataParams
                )
            }
        }
    }

    // MARK: - KNN Retrieval

    /// Performs K-Nearest Neighbors retrieval against the vector store.
    ///
    /// - Parameters:
    ///   - queryEmbedding: The query vector (must be `embeddingDimension` floats).
    ///   - k: Number of nearest neighbors to retrieve (default: 5, max: 20).
    /// - Returns: Array of `RetrievalResult` ordered by ascending distance.
    /// - Throws: If the query embedding dimension is wrong or the query fails.
    func retrieveNearest(
        queryEmbedding: [Float],
        k: Int = VectorStoreConfig.defaultKnnK,
        scope: RetrievalScope? = nil
    ) async throws -> [RetrievalResult] {
        guard database != nil else {
            throw VectorStoreError.databaseNotOpened
        }

        guard queryEmbedding.count == VectorStoreConfig.embeddingDimension else {
            throw VectorStoreError.dimensionMismatch(
                expected: VectorStoreConfig.embeddingDimension,
                actual: queryEmbedding.count
            )
        }

        let clampedK = min(k, VectorStoreConfig.maxKnnK)

        switch scope {
        case .document(let documentID):
            return try await retrieveNearestRows(
                queryEmbedding: queryEmbedding,
                k: clampedK,
                whereClause: "m.document_id = ?",
                params: [documentID.uuidString]
            )
        case .workspace(let workspaceID):
            return try await retrieveNearestRows(
                queryEmbedding: queryEmbedding,
                k: clampedK,
                whereClause: "m.workspace_id = ?",
                params: [workspaceID.uuidString]
            )
        case .hybrid(let documentID, let workspaceID):
            return try await retrieveHybridNearest(
                queryEmbedding: queryEmbedding,
                k: clampedK,
                documentID: documentID,
                workspaceID: workspaceID
            )
        case .none:
            return try await retrieveNearestRows(
                queryEmbedding: queryEmbedding,
                k: clampedK,
                whereClause: nil,
                params: []
            )
        }
    }

    func retrieveDocumentChunks(documentID: UUID) async throws -> [RetrievalResult] {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        let rows = try await db.query(
            """
            SELECT
                m.chunk_text, m.source_file, m.workspace_id, m.document_id, m.chunk_uuid,
                m.chunk_type, m.chunk_index, m.section_title, m.page_label
            FROM vec_metadata m
            WHERE m.document_id = ?
            ORDER BY m.chunk_index
            """,
            params: [documentID.uuidString]
        )

        return rows.compactMap(Self.retrievalResult(from:))
    }

    // MARK: - Delete

    /// Deletes all embeddings from a specific source file.
    ///
    /// - Parameter sourceFile: The source file path whose chunks should be removed.
    /// - Throws: If the delete operation fails.
    func deleteChunks(forSourceFile sourceFile: String) async throws {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        try await db.transaction {
            // Get rowids to delete
            let rows = try await db.query(
                "SELECT id FROM vec_metadata WHERE source_file = ?",
                params: [sourceFile]
            )

            for row in rows {
                if let rowid = row["id"] as? Int {
                    try await db.execute(
                        "DELETE FROM vec_items WHERE rowid = ?",
                        params: [rowid]
                    )
                }
            }

            // Delete metadata records
            try await db.execute(
                "DELETE FROM vec_metadata WHERE source_file = ?",
                params: [sourceFile]
            )
        }
    }

    func deleteChunks(forDocumentID documentID: UUID) async throws {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        try await db.transaction {
            let rows = try await db.query(
                "SELECT id FROM vec_metadata WHERE document_id = ?",
                params: [documentID.uuidString]
            )

            for row in rows {
                if let rowid = row["id"] as? Int {
                    try await db.execute(
                        "DELETE FROM vec_items WHERE rowid = ?",
                        params: [rowid]
                    )
                }
            }

            try await db.execute(
                "DELETE FROM vec_metadata WHERE document_id = ?",
                params: [documentID.uuidString]
            )
        }
    }

    // MARK: - Statistics

    /// Returns the total number of stored embedding chunks.
    func totalChunkCount() async throws -> Int {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        let result = try await db.query("SELECT COUNT(*) as count FROM vec_metadata")
        if let first = result.first, let count = first["count"] as? Int {
            return count
        }
        return 0
    }

    /// Returns the version of the sqlite-vec extension.
    func sqliteVecVersion() async -> String? {
        return await database?.version()
    }
}

// MARK: - Query Helpers

private extension VectorStore {
    func retrieveHybridNearest(
        queryEmbedding: [Float],
        k: Int,
        documentID: UUID?,
        workspaceID: UUID
    ) async throws -> [RetrievalResult] {
        var combined: [RetrievalResult] = []
        var seen = Set<String>()

        if let documentID {
            let documentResults = try await retrieveNearestRows(
                queryEmbedding: queryEmbedding,
                k: k,
                whereClause: "m.document_id = ?",
                params: [documentID.uuidString]
            )

            for result in documentResults where seen.insert(result.id).inserted {
                combined.append(result)
            }
        }

        let remaining = max(0, k - combined.count)
        guard remaining > 0 else { return combined }

        var workspaceClause = "m.workspace_id = ?"
        var workspaceParams: [any Sendable] = [workspaceID.uuidString]
        if let documentID {
            workspaceClause += " AND (m.document_id IS NULL OR m.document_id != ?)"
            workspaceParams.append(documentID.uuidString)
        }

        let workspaceResults = try await retrieveNearestRows(
            queryEmbedding: queryEmbedding,
            k: remaining,
            whereClause: workspaceClause,
            params: workspaceParams
        )

        for result in workspaceResults where seen.insert(result.id).inserted {
            combined.append(result)
        }

        return combined
    }

    func retrieveNearestRows(
        queryEmbedding: [Float],
        k: Int,
        whereClause: String?,
        params: [any Sendable]
    ) async throws -> [RetrievalResult] {
        guard let db = database else {
            throw VectorStoreError.databaseNotOpened
        }

        let filter = whereClause.map { " AND \($0)" } ?? ""
        let sql = """
            SELECT
                m.chunk_text, m.source_file, m.workspace_id, m.document_id, m.chunk_uuid,
                m.chunk_type, m.chunk_index, m.section_title, m.page_label, v.distance
            FROM vec_items v
            JOIN vec_metadata m ON m.id = v.rowid
            WHERE v.embedding MATCH ? AND k = ?\(filter)
            ORDER BY v.distance
            """

        var queryParams: [any Sendable] = [queryEmbedding, k]
        queryParams.append(contentsOf: params)

        let rows = try await db.query(sql, params: queryParams)
        return rows.compactMap(Self.retrievalResult(from:))
    }

    static func retrievalResult(from row: [String: any Sendable]) -> RetrievalResult? {
        guard let text = row["chunk_text"] as? String,
              let sourceFile = row["source_file"] as? String,
              let chunkType = row["chunk_type"] as? String,
              let chunkIndex = row["chunk_index"] as? Int else {
            return nil
        }

        let distanceValue = (row["distance"] as? Double) ?? 0
        let workspaceID = (row["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
        let documentID = (row["document_id"] as? String).flatMap(UUID.init(uuidString:))
        let chunkID = (row["chunk_uuid"] as? String).flatMap(UUID.init(uuidString:))

        return RetrievalResult(
            text: text,
            sourceFile: sourceFile,
            workspaceID: workspaceID,
            documentID: documentID,
            chunkID: chunkID,
            distance: Float(distanceValue),
            chunkType: chunkType,
            chunkIndex: chunkIndex,
            sectionTitle: row["section_title"] as? String,
            pageLabel: row["page_label"] as? String
        )
    }
}

// MARK: - Errors

/// Errors specific to the vector store operations.
enum VectorStoreError: LocalizedError {
    case databaseNotOpened
    case dimensionMismatch(expected: Int, actual: Int)
    case databaseInitializationFailed(underlying: Error)
    case queryFailed(sql: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .databaseNotOpened:
            return "Vector database has not been opened. Call open() first."
        case .dimensionMismatch(let expected, let actual):
            return "Embedding dimension mismatch: expected \(expected), got \(actual)"
        case .databaseInitializationFailed(let underlying):
            return "Failed to initialize vector database: \(underlying.localizedDescription)"
        case .queryFailed(let sql, let underlying):
            return "Vector query failed [\(sql)]: \(underlying.localizedDescription)"
        }
    }
}
