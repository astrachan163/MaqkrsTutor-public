//
//  MaqkrsTutorApp.swift
//  MaqkrsTutor
//
//  App/ — Application entry point
//  Phase 5.5 (April 4, 2026)
//
//  Initializes:
//  - SwiftData ModelContainer (CourseWorkspace, SourceDocument, ChatSession, MessageTurn, StudyArtifact)
//  - ModelManager (@Observable, injected via environment)
//
//  Migration policy: if the persistent store is incompatible (schema change),
//  delete and recreate it rather than crashing. Session data is local/ephemeral;
//  vector embeddings live in a separate SQLite file managed by VectorStore.
//
//  Created by Andrew Strachan on 4/3/26.
//

import SwiftUI
import SwiftData

@main
struct MaqkrsTutorApp: App {
    /// SwiftData container for local persistence.
    /// Schemas: CourseWorkspace, SourceDocument, ChatSession, MessageTurn, StudyArtifact.
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CourseWorkspace.self,
            SourceDocument.self,
            ChatSession.self,
            MessageTurn.self,
            StudyArtifact.self,
        ])

        let environment = ProcessInfo.processInfo.environment
        let isTestRun =
            environment["MAQKRS_UI_TEST_IN_MEMORY"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isTestRun
        )

        // Attempt 1: open the existing store (succeeds if schema is compatible)
        if let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
            return container
        }

        // Attempt 2: schema mismatch — delete and recreate the store.
        // This is safe because vector embeddings live in a separate VectorStore SQLite file.
        if !isTestRun {
            Self.nukeSwiftDataStore()
        }

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Fall back to in-memory persistence instead of crashing the app.
            return Self.makeInMemoryFallbackContainer(schema: schema, originalError: error)
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1100, height: 750)
    }
}

// MARK: - Store Reset

private extension MaqkrsTutorApp {
    static func makeInMemoryFallbackContainer(schema: Schema, originalError: Error) -> ModelContainer {
        let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: [inMemoryConfig])
        } catch {
            preconditionFailure(
                "Could not create ModelContainer. Disk error: \(originalError). In-memory fallback error: \(error)"
            )
        }
    }

    /// Removes the incompatible SwiftData store files from Application Support.
    /// Called only when the container fails to open (schema migration required).
    static func nukeSwiftDataStore() {
        let fm = FileManager.default
        let storeNames = ["default.store", "default.store-shm", "default.store-wal"]

        for directory in candidateStoreDirectories(fileManager: fm) {
            for name in storeNames {
                let url = directory.appendingPathComponent(name)
                try? fm.removeItem(at: url)
            }
        }
    }

    static func candidateStoreDirectories(fileManager fm: FileManager) -> [URL] {
        var directories: [URL] = []

        if let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            directories.append(appSupport)
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            let containerAppSupport = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Library/Application Support")
            directories.append(containerAppSupport)
        }

        return Array(Set(directories))
    }
}
