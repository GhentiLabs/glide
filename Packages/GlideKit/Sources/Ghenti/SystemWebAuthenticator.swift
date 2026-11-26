import AppKit
import AuthenticationServices

/// Ghenti's pages in the system sign-in sheet. The callback is an https URL on a domain only Glide can claim
/// (associated domains, `webcredentials:glide.ghenti.com`), so no other app can catch the code or the key.
@MainActor
public final class SystemWebAuthenticator: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    public override init() {}

    public nonisolated func authenticate(_ url: URL, callbackHost: String, callbackPath: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: url, callback: .https(host: callbackHost, path: callbackPath)) { url, error in
                    if let url { return continuation.resume(returning: url) }
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? GhentiError.cancelled : error ?? GhentiError.cancelled)
                }
                // Shares Safari's sign-in, so a Ghenti session and passkeys already on this Mac work.
                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = self
                self.session = session
                if !session.start() { continuation.resume(throwing: GhentiError.cancelled) }
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey } ?? NSWindow()
    }
}
