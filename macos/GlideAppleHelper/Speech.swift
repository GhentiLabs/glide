import AVFoundation
import Foundation
import Speech

extension GlideAppleHelper {
    static func speechModels() async throws -> [AppleSpeechModelResponse] {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Speech locale models require macOS 26 or newer")
        }

        try requireSignedHelper("Apple Speech locale access")

        guard SpeechTranscriber.isAvailable else {
            throw HelperError("SpeechTranscriber is unavailable")
        }

        let auth = await speechAuthorization()
        switch auth {
        case .authorized:
            break
        case .notDetermined:
            throw HelperError("speech recognition permission was not determined")
        case .denied:
            throw HelperError("speech recognition permission denied")
        case .restricted:
            throw HelperError("speech recognition permission restricted")
        @unknown default:
            throw HelperError("unknown speech recognition authorization status")
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard !supportedLocales.isEmpty else {
            throw HelperError("Apple Speech returned no supported locales")
        }

        let installedLocales = await SpeechTranscriber.installedLocales
        let reservedLocales = await AssetInventory.reservedLocales

        var models: [AppleSpeechModelResponse] = []
        for locale in supportedLocales {
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let status = await AssetInventory.status(forModules: [transcriber])
            let localeId = locale.identifier
            let displayName = Locale.current.localizedString(forIdentifier: localeId) ?? localeId
            models.append(
                AppleSpeechModelResponse(
                    id: modelId(for: locale),
                    displayName: displayName,
                    localeId: localeId,
                    status: status.description,
                    installed: installedLocales.contains(where: { sameLocale($0, locale) }),
                    reserved: reservedLocales.contains(where: { sameLocale($0, locale) })
                )
            )
        }

        return models.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func installSpeechModel(_ request: SpeechModelRequest) async throws {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Speech locale models require macOS 26 or newer")
        }

        try requireSignedHelper("Apple Speech locale access")

        let locale = try await locale(forModelId: request.modelId)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            printInstallEvent(
                AppleSpeechInstallEvent(
                    ok: true,
                    event: "progress",
                    modelId: request.modelId,
                    fractionCompleted: installer.progress.fractionCompleted,
                    completedUnitCount: installer.progress.completedUnitCount,
                    totalUnitCount: installer.progress.totalUnitCount
                )
            )

            let observation = installer.progress.observe(
                \.fractionCompleted,
                options: [.new]
            ) { progress, _ in
                printInstallEvent(
                    AppleSpeechInstallEvent(
                        ok: true,
                        event: "progress",
                        modelId: request.modelId,
                        fractionCompleted: progress.fractionCompleted,
                        completedUnitCount: progress.completedUnitCount,
                        totalUnitCount: progress.totalUnitCount
                    )
                )
            }
            defer {
                observation.invalidate()
            }

            try await installer.downloadAndInstall()
        }

        _ = try await AssetInventory.reserve(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            throw HelperError("Apple Speech model is \(status.description)")
        }

        printInstallEvent(
            AppleSpeechInstallEvent(
                ok: true,
                event: "finished",
                modelId: request.modelId,
                fractionCompleted: 1.0
            )
        )
    }

    static func releaseSpeechModel(_ request: SpeechModelRequest) async throws {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Speech locale models require macOS 26 or newer")
        }

        try requireSignedHelper("Apple Speech locale access")

        let locale = try await locale(forModelId: request.modelId)
        _ = await AssetInventory.release(reservedLocale: locale)
    }

    static func transcribe(_ request: TranscribeRequest) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Speech locale models require macOS 26 or newer")
        }

        let runtime = Runtime()
        return try await runtime.transcribe(request)
    }

    static func speechAvailability() -> (available: Bool, reason: String) {
        guard #available(macOS 26.0, *) else {
            return (false, "requires macOS 26 or newer")
        }

        guard helperTeamIdentifier() != nil else {
            return (false, "requires a signed app with a team identifier")
        }

        guard SpeechTranscriber.isAvailable else {
            return (false, "SpeechTranscriber is unavailable")
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return (true, "available")
        case .notDetermined:
            return (true, "permission not requested")
        case .denied:
            return (false, "permission denied")
        case .restricted:
            return (false, "permission restricted")
        @unknown default:
            return (false, "unknown authorization status")
        }
    }

    static func locale(forModelId modelId: String) async throws -> Locale {
        guard #available(macOS 26.0, *) else {
            throw HelperError("Apple Speech locale models require macOS 26 or newer")
        }

        guard modelId.hasPrefix(appleSpeechModelPrefix) else {
            throw HelperError("Invalid Apple Speech model id: \(modelId)")
        }

        let requestedId = String(modelId.dropFirst(appleSpeechModelPrefix.count))
        let requested = Locale(identifier: requestedId)
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return supported
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        if let exact = supportedLocales.first(where: { normalizedIdentifier($0) == normalizedIdentifier(requested) }) {
            return exact
        }

        throw HelperError("No Apple Speech model found for \(modelId)")
    }

    @available(macOS 26.0, *)
    static func makeSpeechTranscriber(locale: Locale) -> SpeechTranscriber {
        let transcriptionOptions = Set<SpeechTranscriber.TranscriptionOption>()
        let reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.fastResults]
        let attributeOptions = Set<SpeechTranscriber.ResultAttributeOption>()
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: transcriptionOptions,
            reportingOptions: reportingOptions,
            attributeOptions: attributeOptions
        )
    }

    static func modelId(for locale: Locale) -> String {
        "\(appleSpeechModelPrefix)\(locale.identifier)"
    }

    static func sameLocale(_ lhs: Locale, _ rhs: Locale) -> Bool {
        normalizedIdentifier(lhs) == normalizedIdentifier(rhs)
    }

    static func normalizedIdentifier(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "-", with: "_").lowercased()
    }

    static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

@available(macOS 26.0, *)
extension Runtime {
    func transcribe(_ request: TranscribeRequest) async throws -> String {
        try GlideAppleHelper.requireSignedHelper("Apple Speech")

        let auth = await GlideAppleHelper.speechAuthorization()
        guard auth == .authorized else {
            throw HelperError("Speech recognition permission is not authorized")
        }

        let modelId = request.modelId ?? "\(appleSpeechModelPrefix)\(Locale.current.identifier)"
        let locale = try await preparedSpeechLocale(for: modelId)
        let audioURL = URL(fileURLWithPath: request.audioPath)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let transcriber = GlideAppleHelper.makeSpeechTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime
            )
        )

        try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)

        let resultTask = Task {
            var parts: [String] = []
            for try await result in transcriber.results {
                if result.isFinal {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        parts.append(text)
                    }
                }
            }
            return parts.joined(separator: " ")
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            let text = try await resultTask.value
            guard !text.isEmpty else {
                throw HelperError("Apple Speech returned an empty transcript")
            }
            return text
        } catch {
            resultTask.cancel()
            throw error
        }
    }

    private func preparedSpeechLocale(for modelId: String) async throws -> Locale {
        if let locale = speechLocales[modelId] {
            return locale
        }

        let locale = try await GlideAppleHelper.locale(forModelId: modelId)
        let transcriber = GlideAppleHelper.makeSpeechTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            throw HelperError("Apple Speech model \(modelId) is \(status.description)")
        }

        if !reservedSpeechModels.contains(modelId) {
            _ = try await AssetInventory.reserve(locale: locale)
            reservedSpeechModels.insert(modelId)
        }
        speechLocales[modelId] = locale
        return locale
    }
}

@available(macOS 26.0, *)
extension AssetInventory.Status {
    var description: String {
        switch self {
        case .unsupported:
            return "unsupported"
        case .supported:
            return "supported"
        case .downloading:
            return "downloading"
        case .installed:
            return "installed"
        @unknown default:
            return "unknown"
        }
    }
}
