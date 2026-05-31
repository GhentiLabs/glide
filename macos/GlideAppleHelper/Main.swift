import Foundation

@main
struct GlideAppleHelper {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            printResponse(.failure("missing helper command"))
            return
        }

        do {
            switch CommandLine.arguments[1] {
            case "capabilities":
                printResponse(capabilities())
            case "speech-models":
                do {
                    let models = try await speechModels()
                    printResponse(
                        HelperResponse(
                            ok: true,
                            speechModels: models,
                            appleSpeechAvailable: true,
                            appleSpeechReason: "available"
                        )
                    )
                } catch {
                    printResponse(
                        HelperResponse(
                            ok: false,
                            appleSpeechAvailable: false,
                            appleSpeechReason: error.localizedDescription,
                            error: error.localizedDescription
                        )
                    )
                }
            case "foundation-models":
                let models = foundationModels()
                printResponse(HelperResponse(ok: true, foundationModels: models))
            case "install-speech-model":
                let request: SpeechModelRequest = try readStdinJSON()
                do {
                    try await installSpeechModel(request)
                } catch {
                    printInstallEvent(
                        AppleSpeechInstallEvent(
                            ok: false,
                            event: "failed",
                            modelId: request.modelId,
                            error: error.localizedDescription
                        )
                    )
                }
            case "release-speech-model":
                let request: SpeechModelRequest = try readStdinJSON()
                try await releaseSpeechModel(request)
                printResponse(HelperResponse(ok: true))
            case "serve":
                await serve()
            case "transcribe":
                let request: TranscribeRequest = try readStdinJSON()
                if request.profile == true {
                    let result = try await transcribeProfiled(request)
                    printResponse(HelperResponse(ok: true, text: result.text, timings: result.timings))
                } else {
                    let text = try await transcribe(request)
                    printResponse(HelperResponse(ok: true, text: text))
                }
            case "cleanup":
                let request: CleanupRequest = try readStdinJSON()
                if request.profile == true {
                    let result = try await cleanupProfiled(request)
                    printResponse(HelperResponse(ok: true, text: result.text, timings: result.timings))
                } else {
                    let text = try await cleanup(request)
                    printResponse(HelperResponse(ok: true, text: text))
                }
            case "prewarm-foundation":
                let request: CleanupRequest = try readStdinJSON()
                try await prewarmFoundation(request)
                printResponse(HelperResponse(ok: true))
            default:
                printResponse(.failure("unknown helper command: \(CommandLine.arguments[1])"))
            }
        } catch {
            printResponse(.failure(error.localizedDescription))
        }
    }

    static func capabilities() -> HelperResponse {
        let speech = speechAvailability()
        let foundation = foundationAvailability()
        return HelperResponse(
            ok: true,
            appleSpeechAvailable: speech.available,
            appleSpeechReason: speech.reason,
            foundationModels: foundation.models,
            foundationModelsAvailable: foundation.available,
            foundationModelsReason: foundation.reason
        )
    }
}
