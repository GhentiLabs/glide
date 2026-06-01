import Foundation

let appleSpeechModelPrefix = "speechanalyzer-"
let appleFoundationDefaultModelId = "apple-foundation-default"

struct HelperResponse: Encodable {
    var ok: Bool
    var text: String?
    var speechModels: [AppleSpeechModelResponse]?
    var appleSpeechAvailable: Bool?
    var appleSpeechReason: String?
    var foundationModels: [AppleFoundationModelResponse]?
    var foundationModelsAvailable: Bool?
    var foundationModelsReason: String?
    var error: String?
}

struct AppleSpeechModelResponse: Encodable {
    var id: String
    var displayName: String
    var localeId: String
    var status: String
    var installed: Bool
    var reserved: Bool
}

struct AppleFoundationModelDef {
    var id: String
    var displayName: String
    var modelName: String
}

struct AppleFoundationModelResponse: Encodable {
    var id: String
    var displayName: String
    var modelName: String
    var available: Bool
    var reason: String
}

struct AppleSpeechInstallEvent: Encodable {
    var ok: Bool
    var event: String
    var modelId: String
    var fractionCompleted: Double?
    var completedUnitCount: Int64?
    var totalUnitCount: Int64?
    var error: String?
}

struct TranscribeRequest: Decodable {
    var audioPath: String
    var modelId: String?
}

struct SpeechModelRequest: Decodable {
    var modelId: String
}

struct CleanupRequest: Decodable {
    var modelId: String?
    var systemPrompt: String
    var userPrompt: String
}

struct HelperError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

extension HelperResponse {
    static func failure(_ message: String) -> HelperResponse {
        HelperResponse(ok: false, error: message)
    }
}
