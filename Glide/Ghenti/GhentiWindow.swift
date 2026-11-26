import Ghenti
import GlideCore
import SwiftUI

/// The Ghenti sign-in page, in Ghenti's own type and colours. The sign-in itself happens on auth.ghenti.com
/// in the system sheet; this page says what it's for and walks through the vault.
struct GhentiWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        GhentiSignIn(close: { dismissWindow(id: "ghenti") })
            .padding(40)
            .frame(width: 520)
            .background(Ghenti.surface)
            .onAppear { NSApp.activate() }
    }
}

/// The card itself: signed out, signed in without the vault key, or ready.
struct GhentiSignIn: View {
    @Environment(AppModel.self) private var app
    var width: CGFloat = 400
    /// "Not now" and "Done" call this.
    var close: (() -> Void)?

    private var account: Account { app.account }

    var body: some View {
        GhentiCard(width: width) {
            GhentiWordmark(height: 24).padding(.bottom, 22)
            if let user = account.user {
                signedIn(user)
            } else {
                signedOut
            }
            if let activity = account.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                }
                .font(Ghenti.font(13)).foregroundStyle(Ghenti.muted).padding(.top, 14)
            } else if let problem = account.problem {
                Text(problem).font(Ghenti.font(13)).foregroundStyle(Ghenti.error).padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Ghenti.ink)
        .animation(Tokens.spring, value: account.user)
        .animation(Tokens.spring, value: account.hasKey)
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in to Glide").font(Ghenti.font(19, .semibold)).accessibilityAddTraits(.isHeader)
            Text("With a Ghenti account, Glide can sync your dictations across your Macs, encrypted with your Ghenti vault key. With your vault set to Only me, nobody but you can read them.")
                .font(Ghenti.font(15)).foregroundStyle(Ghenti.muted).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            Button("Continue with Ghenti") { Task { await account.signIn() } }
                .buttonStyle(GhentiButtonStyle()).padding(.top, 24)
                .disabled(account.activity != nil)
            if let close {
                Button("Not Now", action: close).buttonStyle(GhentiButtonStyle(secondary: true)).padding(.top, 10)
            }
        }
    }

    private func signedIn(_ user: GhentiUser) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(user.name.map { "Signed in as \($0)" } ?? "Signed in").font(Ghenti.font(19, .semibold))
                .accessibilityAddTraits(.isHeader)
            if let email = user.email { Text(email).font(Ghenti.font(15)).foregroundStyle(Ghenti.muted).padding(.top, 4) }
            if account.syncEnabled && !account.hasKey {
                Text("Unlock your Ghenti vault so Glide can encrypt what it syncs. Your passkey, recovery code or another signed-in device unlocks it.")
                    .font(Ghenti.font(15)).foregroundStyle(Ghenti.muted).padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Unlock Vault") { Task { await account.unlock() } }
                    .buttonStyle(GhentiButtonStyle()).padding(.top, 20)
                    .disabled(account.activity != nil)
            }
            if let close {
                Button("Done", action: close).buttonStyle(GhentiButtonStyle(secondary: account.syncEnabled && !account.hasKey))
                    .padding(.top, 10)
            }
        }
    }
}
