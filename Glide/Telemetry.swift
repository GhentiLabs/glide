import Aptabase
import Foundation
import Sentry

/// Opt-in crash reports (self-hosted Sentry) and usage statistics (self-hosted Aptabase), both off until turned on.
/// Neither ever carries dictated text, field contents, app names or anything that identifies the person.
@MainActor
enum Telemetry {
    /// Ghenti's own servers. Empty until that service is deployed, and then nothing is sent for it.
    static let sentryDSN = ""
    static let aptabaseKey = ""
    static let aptabaseHost = "https://aptabase.ghenti.com"

    static var crashReports: Bool {
        get { UserDefaults.standard.bool(forKey: "crashReports") }
        set {
            UserDefaults.standard.set(newValue, forKey: "crashReports")
            newValue ? startCrashReports() : SentrySDK.close()
        }
    }

    static var usageStatistics: Bool {
        get { UserDefaults.standard.bool(forKey: "usageStatistics") }
        set {
            UserDefaults.standard.set(newValue, forKey: "usageStatistics")
            if newValue { startUsage() }
        }
    }

    static func start() {
        if crashReports { startCrashReports() }
        if usageStatistics { startUsage() }
    }

    /// A usage event with coarse, content-free properties. Dropped unless the person opted in.
    static func event(_ name: String, _ props: [String: Value] = [:]) {
        guard usageStatistics, usageStarted else { return }
        Aptabase.shared.trackEvent(name, with: props)
    }

    private static var usageStarted = false

    private static func startUsage() {
        guard !aptabaseKey.isEmpty, !usageStarted else { return }
        Aptabase.shared.initialize(appKey: aptabaseKey, with: InitOptions(host: aptabaseHost))
        usageStarted = true
    }

    private static func startCrashReports() {
        guard !sentryDSN.isEmpty, !SentrySDK.isEnabled else { return }
        SentrySDK.start { options in
            options.dsn = sentryDSN
            options.sendDefaultPii = false
            options.enableUncaughtNSExceptionReporting = true  // macOS misses uncaught exceptions without it
            options.enableMetricKit = true  // hangs and resource diagnostics
            options.tracesSampleRate = 0
            // No breadcrumbs: they could hold clipboard, window titles or log lines with dictated text.
            options.maxBreadcrumbs = 0
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil
                event.request = nil
                event.extra = nil
                event.message = event.message.map { _ in SentryMessage(formatted: "message removed") }
                return event
            }
        }
    }
}
