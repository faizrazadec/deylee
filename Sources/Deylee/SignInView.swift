import DeyleeKit
import SwiftUI

/// The window that stands between a fresh install and the app.
///
/// From the UI spec, section 11: 380 wide, native title bar, shown once, before
/// the tray item appears. Taller than the spec's 420 because that layout assumed a
/// sign-in link and no password field; everything else — copy, rhythm, the amber
/// error line, the disabled primary — follows it.
///
/// Sign-in is a gate, not a preference. Deylee is a synced product now, and an
/// account that is optional is an account most people never make, which leaves
/// them with a local tracker and no history when they change machines.
///
/// The one exception is a first run with no network, which would otherwise be an
/// app that does nothing at all. That offers to track now and claim the history on
/// the first successful sign-in — nothing is lost, and the app is never a brick.
struct SignInView: View {
    @ObservedObject var auth: AuthService
    /// Called once there is a session, so the app can put its tray item up.
    var onSignedIn: () -> Void
    /// Offered only when the API cannot be reached at all.
    var onContinueOffline: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var mode: Mode = .signIn
    @State private var error: String?
    @State private var offlineOffered = false

    private enum Mode: String, CaseIterable {
        case signIn = "Sign in"
        case signUp = "Create account"
    }

    /// The primary stays disabled until the address parses, per the spec.
    private var emailLooksValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !domain.hasPrefix(".")
    }

    private var canSubmit: Bool {
        emailLooksValid && password.count >= 8 && !isBusy
    }

    private var isBusy: Bool {
        if case .signingIn = auth.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            form
        }
        .frame(width: 380)
        .background(Palette.surface)
        .onChange(of: auth.state) { _, state in
            if case .signedIn = state { onSignedIn() }
            if case .failed(let reason) = state {
                error = reason
                // Only when the API itself is unreachable — a rejected password is
                // not a reason to offer working without an account.
                if reason.localizedCaseInsensitiveContains("could not connect")
                    || reason.localizedCaseInsensitiveContains("offline")
                    || reason.localizedCaseInsensitiveContains("network") {
                    offlineOffered = true
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Space.l) {
            Mark()
            VStack(spacing: Space.xs) {
                Text("Sign in to Deylee")
                    .font(Type.controlLarge.weight(.medium))
                    .foregroundStyle(Palette.fg)
                Text("Only so your log follows you between machines.")
                    .font(Type.small)
                    .foregroundStyle(Palette.fgMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.x6l)
        .padding(.bottom, Space.x5l)
        .padding(.horizontal, Space.x5l)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.x3l) {
            // Centred at its natural width rather than stretched: the enclosing
            // stack is leading-aligned for the field labels, and a full-width
            // segmented control would read as two buttons instead of one choice.
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .center)
            .disabled(isBusy)

            field("EMAIL") {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(Type.body)
                    .foregroundStyle(Palette.fg)
                    .disabled(isBusy)
            }

            field("PASSWORD") {
                SecureField(mode == .signUp ? "At least 8 characters" : "", text: $password)
                    .textFieldStyle(.plain)
                    .font(Type.body)
                    .foregroundStyle(Palette.fg)
                    .disabled(isBusy)
                    .onSubmit { if canSubmit { submit() } }
            }

            // A single line under the field, never a dialog — spec, section 11.
            if let error {
                Text(error)
                    .font(Type.meta)
                    .foregroundStyle(Palette.breakColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isBusy {
                // Replaces the buttons while the browser has the flow, so nothing
                // looks clickable while it cannot be clicked.
                Text("Waiting for your browser…")
                    .font(Type.small)
                    .foregroundStyle(Palette.fgMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.l)
            } else {
                primaryButton
                orDivider
                googleButton
            }

            if offlineOffered {
                Button("Continue without an account") {
                    onContinueOffline()
                }
                .buttonStyle(.link)
                .font(Type.small)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Text("Tracking works offline — signing in only syncs the log.")
                .font(Type.meta)
                .foregroundStyle(Palette.fgFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.x5l)
        .padding(.top, Space.x4l)
        .padding(.bottom, Space.x5l)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(label)
                .font(Type.caps)
                .foregroundStyle(Palette.fgFaint)
            content()
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.l)
                .background(Palette.raised)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )
        }
    }

    private var primaryButton: some View {
        Button(action: submit) {
            Text(mode == .signUp ? "Create account" : "Continue")
                .font(Type.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.l)
        }
        .buttonStyle(.plain)
        .background(canSubmit ? Palette.accent : Palette.hover)
        .foregroundStyle(canSubmit ? Palette.surface : Palette.fgFaint)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .disabled(!canSubmit)
        .animation(.easeOut(duration: 0.18), value: canSubmit)
    }

    private var orDivider: some View {
        HStack(spacing: Space.xl) {
            Rectangle().fill(Palette.border).frame(height: 1)
            Text("or").font(Type.small).foregroundStyle(Palette.fgFaint)
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    private var googleButton: some View {
        Button {
            error = nil
            Task { await auth.signIn() }
        } label: {
            HStack(spacing: Space.l) {
                GoogleMark()
                Text("Continue with Google")
                    .font(Type.body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.fg)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
    }

    private func submit() {
        error = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            switch mode {
            case .signIn: await auth.signInWithPassword(email: address, password: password)
            case .signUp: await auth.signUp(email: address, password: password)
            }
        }
    }
}

// MARK: - Marks

/// The app's own mark: the status-item glyph at rest, so the window opens with the
/// same shape that will live in the menu bar afterwards.
private struct Mark: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Palette.fgMuted, lineWidth: 1.5)
            Rectangle()
                .fill(Palette.fgMuted)
                .frame(width: 1.5, height: 9)
                .offset(y: -4.5)
        }
        .frame(width: 34, height: 34)
    }
}

/// Google's mark, from the SVG in the design.
///
/// Rendered from the vector rather than approximated, because Google's brand terms
/// do not permit redrawing it. Falls back to a neutral monogram if the platform
/// cannot rasterise the data, which keeps the button usable rather than empty.
private struct GoogleMark: View {
    private static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 48 48">\
        <path fill="#4285F4" d="M45 24.5c0-1.6-.1-2.8-.4-4H24v7.3h12c-.2 2-1.5 5-4.4 7l-.1.3 6.4 4.9.4.1C42.4 36.3 45 30.9 45 24.5"/>\
        <path fill="#34A853" d="M24 46c5.8 0 10.7-1.9 14.3-5.2l-6.8-5.3c-1.8 1.3-4.3 2.2-7.5 2.2-5.7 0-10.6-3.8-12.3-9l-.3.1-6.6 5.1-.1.3C8.3 41.1 15.6 46 24 46"/>\
        <path fill="#FBBC05" d="M11.7 28.7A13.5 13.5 0 0 1 11 24c0-1.6.3-3.2.7-4.7v-.3l-6.7-5.2-.2.1A22 22 0 0 0 2 24c0 3.5.9 6.9 2.8 10.1z"/>\
        <path fill="#EA4335" d="M24 9.5c4 0 6.8 1.8 8.3 3.2l6.1-6C34.6 3.4 29.8 1 24 1 15.6 1 8.3 5.9 4.8 13.9l6.9 5.4C13.4 13.3 18.3 9.5 24 9.5"/>\
        </svg>
        """

    var body: some View {
        if let image = NSImage(data: Data(Self.svg.utf8)) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 15, height: 15)
        } else {
            Text("G")
                .font(Type.body.weight(.bold))
                .foregroundStyle(Palette.fgMuted)
                .frame(width: 15, height: 15)
        }
    }
}
