import Darwin
import Foundation
import FoundationModels

let appleFoundationModelDefs = [
    AppleFoundationModelDef(
        id: appleFoundationDefaultModelId,
        displayName: "Apple Foundation Model",
        modelName: "SystemLanguageModel.default"
    ),
]

extension GlideAppleHelper {
    static func foundationModels() -> [AppleFoundationModelResponse] {
        guard #available(macOS 26.0, *) else {
            return appleFoundationModelDefs.map { def in
                foundationModelResponse(def, available: false, reason: "requires macOS 26 or newer")
            }
        }

        let model = SystemLanguageModel.default
        let reason: String
        switch model.availability {
        case .available:
            reason = "available"
        case .unavailable(let unavailableReason):
            reason = "\(unavailableReason)"
        }

        return appleFoundationModelDefs.map { def in
            foundationModelResponse(def, available: model.isAvailable, reason: reason)
        }
    }

    static func foundationModelResponse(
        _ def: AppleFoundationModelDef,
        available: Bool,
        reason: String
    ) -> AppleFoundationModelResponse {
        AppleFoundationModelResponse(
            id: def.id,
            displayName: def.displayName,
            modelName: def.modelName,
            available: available,
            reason: reason
        )
    }

    static func foundationDefinition(for modelId: String?) throws -> AppleFoundationModelDef {
        let selected = modelId ?? appleFoundationDefaultModelId
        guard let def = appleFoundationModelDefs.first(where: { $0.id == selected }) else {
            throw HelperError("Unknown Apple Foundation model: \(selected)")
        }
        return def
    }

    static func foundationLanguageModel(for modelId: String?) throws -> SystemLanguageModel {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Foundation Models require macOS 26 or newer")
        }

        _ = try foundationDefinition(for: modelId)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model
        case .unavailable(let reason):
            throw HelperError("Apple Foundation Model unavailable: \(reason)")
        }
    }

    static func cleanup(_ request: CleanupRequest) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Foundation Models require macOS 26 or newer")
        }

        let runtime = Runtime()
        return try await runtime.cleanup(request)
    }

    static func prewarmFoundation(_ request: CleanupRequest) async throws {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Foundation Models require macOS 26 or newer")
        }

        let runtime = Runtime()
        return try await runtime.prewarmFoundation(request)
    }

    static func foundationAvailability() -> (
        available: Bool,
        reason: String,
        models: [AppleFoundationModelResponse]
    ) {
        let models = foundationModels()
        let availableCount = models.filter(\.available).count
        if availableCount > 0 {
            let label = availableCount == 1 ? "1 available model" : "\(availableCount) available models"
            return (true, label, models)
        }

        let reason = models.first?.reason ?? "unavailable"
        return (false, reason, models)
    }
}

@available(macOS 26.0, *)
extension Runtime {
    func cleanup(_ request: CleanupRequest) async throws -> String {
        let key = foundationSessionKey(modelId: request.modelId, systemPrompt: request.systemPrompt)
        let session = try takeWarmFoundationSession(for: key)
            ?? makeWarmFoundationSession(modelId: request.modelId, systemPrompt: request.systemPrompt)
        let response = try await session.respond(
            to: request.userPrompt,
            options: GenerationOptions(
                sampling: .greedy,
                temperature: 0,
                maximumResponseTokens: 512
            )
        )
        Task {
            self.prepareWarmFoundationSession(
                modelId: request.modelId,
                systemPrompt: request.systemPrompt
            )
        }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func takeWarmFoundationSession(for key: String) -> LanguageModelSession? {
        guard var sessions = foundationSessions[key], !sessions.isEmpty else {
            return nil
        }
        let session = sessions.removeFirst()
        foundationSessions[key] = sessions
        return session
    }

    private func prepareWarmFoundationSession(modelId: String?, systemPrompt: String) {
        let key = foundationSessionKey(modelId: modelId, systemPrompt: systemPrompt)
        if (foundationSessions[key]?.count ?? 0) >= maxWarmFoundationSessionsPerKey {
            return
        }

        do {
            let session = try makeWarmFoundationSession(modelId: modelId, systemPrompt: systemPrompt)
            foundationSessions[key, default: []].append(session)
        } catch {
            fputs("[glide] Apple Foundation prewarm failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func prewarmFoundation(_ request: CleanupRequest) throws {
        let key = foundationSessionKey(modelId: request.modelId, systemPrompt: request.systemPrompt)
        if (foundationSessions[key]?.count ?? 0) >= maxWarmFoundationSessionsPerKey {
            return
        }

        let session = try makeWarmFoundationSession(
            modelId: request.modelId,
            systemPrompt: request.systemPrompt
        )
        foundationSessions[key, default: []].append(session)
    }

    private func makeWarmFoundationSession(
        modelId: String?,
        systemPrompt: String
    ) throws -> LanguageModelSession {
        let model = try GlideAppleHelper.foundationLanguageModel(for: modelId)
        let session = LanguageModelSession(model: model, instructions: systemPrompt)
        session.prewarm()
        return session
    }

    private func foundationSessionKey(modelId: String?, systemPrompt: String) -> String {
        "\(modelId ?? appleFoundationDefaultModelId)\u{1F}\(systemPrompt)"
    }
}
