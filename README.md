# MaqkrsTutor

MaqkrsTutor is a local-first macOS study assistant built with SwiftUI. It helps students upload course materials, focus a document, choose a study action, and get grounded responses from locally running Gemma models through Ollama.

This public copy is sanitized for portfolio sharing. It excludes private notes, local-only artifacts, and git history from the private working repository.

## What It Does

- Creates workspace-based study sessions for course materials.
- Supports grounded workflows for PDF, Markdown/text, and source code documents.
- Uses a deterministic chat orchestrator so actions like summarize, translate, explain, and practice follow the selected document and language instead of drifting across unrelated session history.
- Stores local study context with SwiftData and retrieval embeddings with sqlite-vec.
- Streams responses and thinking output from Ollama-hosted Gemma models on-device.

## Project Highlights

- Deterministic turn resolution with explicit source selection, language selection, and study-mode routing.
- Focused-document RAG with provenance metadata and scoped history windows.
- Local document ingestion pipeline for PDF, text, and code content.
- Curated model selection for Gemma variants hosted by Ollama.
- Workspace-first SwiftUI sidebar and study context UI.

## Tech Stack

- SwiftUI
- SwiftData
- Ollama
- Gemma 4
- MLX
- SQLiteVec
- MarkdownUI
- PDFKit
- AVFoundation

## Repository Layout

- `MaqkrsTutor/App`: app entry point and app-level setup
- `MaqkrsTutor/Core/Chat`: deterministic turn orchestration
- `MaqkrsTutor/Core/Data`: SwiftData models
- `MaqkrsTutor/Core/MLX`: model management and streaming
- `MaqkrsTutor/Core/RAG`: ingestion pipeline and vector retrieval
- `MaqkrsTutor/UI`: SwiftUI views and components
- `MaqkrsTutor/Scripts`: helper scripts for chunking and preprocessing

## Running Locally

### Requirements

- macOS
- Xcode 26+
- Ollama installed and running locally
- A supported Gemma model pulled in Ollama
- `nomic-embed-text:v1.5` if you want embedding-backed retrieval

### Typical Ollama setup

```bash
ollama pull gemma4:e2b-it-q4_K_M
ollama pull gemma4:e4b-it-q4_K_M
ollama pull nomic-embed-text:v1.5
ollama serve
```

### Open and build

1. Open `MaqkrsTutor.xcodeproj` in Xcode.
2. If needed, set your own signing team and bundle identifier.
3. Build and run the `MaqkrsTutor` target.

## Current Scope

This public version is focused on the macOS local-study workflow:

- PDF, Markdown/text, and code documents are the primary grounded study materials.
- Images are treated as prompt-scoped attachments.
- Audio, video, PPT, and repo-folder ingestion are still exploratory and not positioned as polished public features here.

## Why This Project Matters

I built MaqkrsTutor as a local AI learning platform for course-specific study support. The goal is to combine document-grounded tutoring, summarization, translation, and practice generation in a way that is predictable, privacy-preserving, and usable on a Mac without depending on cloud-hosted model APIs.

## Public Copy Notes

- This repository was published as a fresh public-safe copy.
- Private planning notes, local logs, and internal docs were removed.
- Local bundle identifiers and Xcode signing values were neutralized for public sharing.

## License

MIT. See [LICENSE](LICENSE).
