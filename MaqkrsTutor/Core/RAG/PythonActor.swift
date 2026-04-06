//
//  PythonActor.swift
//  MaqkrsTutor
//
//  Core/RAG — GIL-safe serial actor for all PythonKit calls
//  Phase 6: Document Ingestion Pipeline
//
//  CRITICAL SAFETY NOTE:
//  Python has a Global Interpreter Lock (GIL). If PythonKit is called
//  from concurrent Task.detached blocks simultaneously, macOS will crash
//  with a kernel-level thread collision. This @globalActor wraps a single
//  dedicated serial DispatchQueue to prevent that — enforced at compile time.
//
//  All functions that call PythonKit MUST be annotated @PythonActor.
//

import Foundation

// MARK: - Python Executor

/// A custom serial executor backed by a single-threaded DispatchQueue.
/// This ensures Python's GIL is never contested by concurrent Swift tasks.
final class PythonSerialExecutor: SerialExecutor {
    static let shared = PythonSerialExecutor()

    private let queue = DispatchQueue(
        label: "com.maqkrstutor.python.executor",
        qos: .userInitiated,
        attributes: []  // Serial — NOT .concurrent
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async {
            unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

// MARK: - PythonActor Global Actor

/// A `@globalActor` that serializes all PythonKit calls through a single
/// dedicated queue, guaranteeing GIL safety under Swift 6 strict concurrency.
///
/// Usage:
/// ```swift
/// @PythonActor
/// func chunkDocument(text: String) throws -> [TextChunk] {
///     let chunker = Python.import("semantic_chunker")
///     // ... PythonKit calls are safe here
/// }
/// ```
///
/// Never call PythonKit outside of a `@PythonActor`-isolated function.
@globalActor
actor PythonActor: GlobalActor {
    static let shared = PythonActor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        PythonSerialExecutor.shared.asUnownedSerialExecutor()
    }
}
