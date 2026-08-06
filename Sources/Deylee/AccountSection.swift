import DeyleeKit
import SwiftUI

/// The account and sync section of Settings.
///
/// Kept in its own file because it is the one part of Settings backed by a network
/// service rather than a preference, and because it must degrade to nothing at all:
/// a build with no API configured has no coordinator, and this view simply is not
/// shown. Sync is optional, and the settings window has to reflect that.
struct AccountSection: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var sync: SyncService

    var body: some View {
        SettingsSectionCard(
            title: "Account",
            description: "Sign in to keep your hours on every device. Deylee works fully without it."
        ) {
            switch auth.state {
            case .signedOut:
                signedOut
            case .signingIn:
                row("Signing in…", detail: "Finish in the browser window that just opened.")
            case .signedIn(let email, _):
                signedIn(email: email)
            case .failed(let reason):
                signedOut
                row("Sign-in failed", detail: reason, tone: .warning)
            }
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            row(
                "Not signed in",
                detail: "Your hours stay on this Mac. Nothing is uploaded."
            )
            Button("Continue with Google") {
                Task { await auth.signIn() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func signedIn(email: String) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            row("Signed in", detail: email)
            row("Sync", detail: syncDetail, tone: syncTone)
            HStack(spacing: Space.m) {
                Button("Sync now") {
                    Task { await sync.syncNow() }
                }
                Button("Sign out") {
                    auth.signOut()
                }
            }
        }
    }

    /// Deliberately concrete. "Something went wrong" tells a user nothing they can
    /// act on; naming the refusal at least tells them whether to retry or to look
    /// at the day it came from.
    private var syncDetail: String {
        switch sync.status {
        case .idle:
            "Waiting for the next check."
        case .syncing:
            "Syncing…"
        case .succeeded(let at):
            "Last synced \(Self.relative(at))."
        case .failed(let reason):
            reason
        case .rejected(let reasons):
            reasons.count == 1
                ? reasons[0]
                : "\(reasons.count) changes were refused. Open History to resolve them."
        }
    }

    private var syncTone: Tone {
        switch sync.status {
        case .failed, .rejected: .warning
        default: .normal
        }
    }

    private enum Tone { case normal, warning }

    private func row(_ label: String, detail: String, tone: Tone = .normal) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label)
                .font(Type.small.weight(.medium))
                .foregroundStyle(Palette.fg)
            Text(detail)
                .font(Type.small)
                .foregroundStyle(tone == .warning ? Palette.danger : Palette.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func relative(_ at: EpochMs) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: Double(at) / 1000), relativeTo: Date()
        )
    }
}
