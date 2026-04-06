//
//  ModelSelectorView.swift
//  MaqkrsTutor
//
//  UI/Components — Installed-model selector with memory warnings
//

import SwiftUI

struct ModelSelectorView: View {
    @Bindable var modelManager: ModelManager
    @Binding var selectedModelId: String

    @State private var showMemoryWarning = false

    private var availableModels: [ModelDescriptor] {
        let installed = modelManager.installedModels
        if installed.isEmpty {
            return [ModelManager.descriptor(for: selectedModelId)]
        }
        return installed
    }

    private var curatedModels: [ModelDescriptor] {
        let models = availableModels.filter { $0.supportsChat && $0.visibility == .curated }
        if models.isEmpty {
            return availableModels.filter(\.supportsChat)
        }
        return models
    }

    private var advancedModels: [ModelDescriptor] {
        availableModels.filter { !$0.supportsChat || $0.visibility == .advanced }
    }

    private var selectedDescriptor: ModelDescriptor {
        availableModels.first { $0.id == selectedModelId } ?? ModelManager.descriptor(for: selectedModelId)
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: { selectedModelId },
            set: { newValue in
                selectedModelId = newValue
                showMemoryWarning = descriptor(for: newValue).requiresMemoryWarning
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Model", selection: pickerSelection) {
                Section("Chat Models") {
                    ForEach(curatedModels) { model in
                        modelRow(for: model)
                    }
                }

                if !advancedModels.isEmpty {
                    Section("Advanced") {
                        ForEach(advancedModels) { model in
                            modelRow(for: model)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("model-picker")

            Circle()
                .fill(modelManager.isOllamaAvailable ? .green : .red)
                .frame(width: 8, height: 8)
                .help(modelManager.isOllamaAvailable
                      ? "Ollama connected at localhost:11434"
                      : "Ollama not reachable")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .alert(
            "⚠️ High Memory Usage",
            isPresented: $showMemoryWarning
        ) {
            Button("Continue Anyway") { }
            Button("Switch to Recommended", role: .cancel) {
                withAnimation(.smooth) {
                    selectedModelId = recommendedModelIdentifier
                }
            }
        } message: {
            Text("""
            The \(selectedDescriptor.displayName) model requires approximately \
            \(Int(selectedDescriptor.estimatedMemoryGB ?? 22)) GB of unified memory. \
            On your M4 Max (48 GB), this may cause thermal throttling \
            or memory pressure during extended sessions.

            The recommended default is \(descriptor(for: recommendedModelIdentifier).displayName).
            """)
        }
    }

    @ViewBuilder
    private func modelRow(for model: ModelDescriptor) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(model.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: model.iconName)
        }
        .tag(model.id)
    }

    private var recommendedModelIdentifier: String {
        ModelManager.resolveModelIdentifier(
            ModelCatalog.recommendedModel,
            installedModelIDs: curatedModels.map(\.id),
            fallback: selectedModelId
        )
    }

    private func descriptor(for identifier: String) -> ModelDescriptor {
        availableModels.first { $0.id == identifier } ?? ModelManager.descriptor(for: identifier)
    }
}

private struct ModelSelectorPreview: View {
    @State private var modelManager: ModelManager = {
        let manager = ModelManager()
        manager.installedModels = ModelCatalog.preferredModelOrder.map(ModelManager.descriptor(for:))
        manager.currentModel = ModelCatalog.recommendedModel
        manager.isOllamaAvailable = true
        return manager
    }()

    @State private var selectedModel = ModelCatalog.recommendedModel

    var body: some View {
        ModelSelectorView(
            modelManager: modelManager,
            selectedModelId: $selectedModel
        )
    }
}

#Preview {
    ModelSelectorPreview()
        .padding()
        .frame(width: 320)
}
