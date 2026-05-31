import Foundation
import FoundationModels

extension GlideAppleHelper {
    static func serve() async {
        guard #available(macOS 26.0, *) else {
            serveUnavailable("Apple local models require macOS 26 or newer")
            return
        }

        let runtime = Runtime()
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let response: HelperResponse
            do {
                response = try await runtime.handle(line)
            } catch {
                response = .failure(error.localizedDescription)
            }
            printResponse(response)
        }
    }

    static func serveUnavailable(_ message: String) {
        while readLine(strippingNewline: true) != nil {
            printResponse(.failure(message))
        }
    }

    struct ServeEnvelope {
        var command: String
        var requestData: Data
    }

    static func decodeServeEnvelope(_ line: String) throws -> ServeEnvelope {
        let data = Data(line.utf8)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let command = object["command"] as? String,
            !command.isEmpty
        else {
            throw HelperError("invalid helper request envelope")
        }

        let request = object["request"] ?? [:]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        return ServeEnvelope(command: command, requestData: requestData)
    }

    static func decodeServeRequest<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}

@available(macOS 26.0, *)
actor Runtime {
    var speechLocales: [String: Locale] = [:]
    var reservedSpeechModels = Set<String>()
    var foundationSessions: [String: [LanguageModelSession]] = [:]
    let maxWarmFoundationSessionsPerKey = 1

    func handle(_ line: String) async throws -> HelperResponse {
        let envelope = try GlideAppleHelper.decodeServeEnvelope(line)
        switch envelope.command {
        case "transcribe":
            let request: TranscribeRequest = try GlideAppleHelper.decodeServeRequest(envelope.requestData)
            if request.profile == true {
                let result = try await transcribeProfiled(request)
                return HelperResponse(ok: true, text: result.text, timings: result.timings)
            }
            let text = try await transcribe(request)
            return HelperResponse(ok: true, text: text)
        case "cleanup":
            let request: CleanupRequest = try GlideAppleHelper.decodeServeRequest(envelope.requestData)
            if request.profile == true {
                let result = try await cleanupProfiled(request)
                return HelperResponse(ok: true, text: result.text, timings: result.timings)
            }
            let text = try await cleanup(request)
            return HelperResponse(ok: true, text: text)
        case "prewarm-foundation":
            let request: CleanupRequest = try GlideAppleHelper.decodeServeRequest(envelope.requestData)
            try prewarmFoundation(request)
            return HelperResponse(ok: true)
        default:
            return .failure("unknown helper command: \(envelope.command)")
        }
    }
}
