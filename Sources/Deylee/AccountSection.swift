import DeyleeKit
import SwiftUI

/// The Account group in Settings.
///
/// From the UI spec, section 09: Account is the first group, "reachable whether or
/// not sign-in was skipped at launch", and its Sign in button "opens the same
/// window as section 11 — no second, smaller form to maintain". So this is a row,
/// never a form; the window is the only place credentials are ever typed.
///
/// Four states, all the same shape — avatar, two lines, one trailing button — so
/// the row never jumps as it moves between them.
struct AccountSection: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var sync: SyncService
    /// Raises the sign-in window. Supplied rather than built here, because the app
    /// owns that window's lifetime and its effect on the activation policy.
    var presentSignIn: () -> Void

    var body: some View {
        SettingsSectionCard(
            title: "Account",
            description: "Sign in to keep your hours on every device. Deylee works fully without it."
        ) {
            switch auth.state {
            case .signedOut, .failed:
                AccountRow(
                    initial: nil,
                    title: "Not signed in",
                    detail: "Log stays on this machine only",
                    action: "Sign in",
                    prominent: true,
                    perform: presentSignIn
                )
            case .signingIn:
                AccountRow(
                    initial: nil,
                    title: "Waiting for your browser…",
                    detail: "Finish in the window that opened",
                    action: "Cancel",
                    perform: auth.cancelSignIn
                )
            case .signedIn(let email, _):
                AccountRow(
                    initial: email.first.map(String.init)?.uppercased(),
                    title: email,
                    detail: syncDetail,
                    action: "Sign out",
                    perform: auth.signOut
                )
                // A @ViewBuilder that resolves to nothing when sync is healthy, so
                // the row simply is not there rather than being there and empty.
                offlineRow
            }
        }
    }

    /// "Synced 2 min ago · Google", per the spec — the provider matters because
    /// somebody with both routes needs to know which one this session came from.
    private var syncDetail: String {
        let provider = auth.currentProvider ?? "Account"
        switch sync.status {
        case .idle:
            return "Waiting for the next check · \(provider)"
        case .syncing:
            return "Syncing… · \(provider)"
        case .succeeded(let at):
            return "Synced \(Self.relative(at)) · \(provider)"
        case .failed:
            return "Sync paused · \(provider)"
        case .rejected(let reasons):
            return reasons.count == 1
                ? reasons[0]
                : "\(reasons.count) changes were refused · \(provider)"
        }
    }

    /// A second row, only while something is actually wrong.
    ///
    /// The spec gives it its own line rather than folding it into the account row,
    /// because "your account" and "sync is behind" are different facts and burying
    /// the second in the first is how people miss it.
    @ViewBuilder private var offlineRow: some View {
        if case .failed(let reason) = sync.status {
            AccountRow(
                initial: nil,
                title: reason.localizedCaseInsensitiveContains("offline")
                    || reason.localizedCaseInsensitiveContains("connect")
                    ? "Sync paused — offline" : "Sync paused",
                detail: "Tracking continues; will catch up",
                action: "Retry",
                tone: .warning,
                perform: { Task { await sync.syncNow() } }
            )
        }
    }

    private static func relative(_ at: EpochMs) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: Double(at) / 1000), relativeTo: Date()
        )
    }
}

/// One account row: avatar, two lines, a trailing button.
private struct AccountRow: View {
    enum Tone { case normal, warning }

    var initial: String?
    var title: String
    var detail: String
    var action: String
    var prominent: Bool = false
    var tone: Tone = .normal
    var perform: () -> Void

    var body: some View {
        HStack(spacing: Space.xl) {
            avatar
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(Type.body)
                    .foregroundStyle(tone == .warning ? Palette.breakColor : Palette.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Type.meta)
                    .foregroundStyle(Palette.fgFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.m)
            Button(action: perform) {
                Text(action)
                    .font(Type.small)
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.s)
            }
            .buttonStyle(.plain)
            .foregroundStyle(prominent ? Palette.surface : Palette.fg)
            .background(prominent ? Palette.accent : Palette.hover)
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The initial when there is one, an outline when there is not — so the row
    /// keeps its rhythm whether or not anybody is signed in.
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(initial == nil ? Color.clear : Palette.hover)
                .overlay(Circle().strokeBorder(Palette.border, lineWidth: 1))
            if let initial {
                Text(initial)
                    .font(Type.small.weight(.medium))
                    .foregroundStyle(Palette.fgMuted)
            }
        }
        .frame(width: 28, height: 28)
    }
}
