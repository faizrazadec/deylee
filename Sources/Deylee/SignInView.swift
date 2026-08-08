import DeyleeKit
import SwiftUI

/// The sign-in window.
///
/// From the UI spec, section 11: 380 wide, native title bar. Taller than the spec's
/// 420 because that layout assumed a sign-in link and no password field; everything
/// else — copy, rhythm, the amber error line, the disabled primary — follows it.
///
/// Raised by the action that needs an account rather than at launch: pressing
/// Start, or asking to sign in from Settings. That timing is the point. An account
/// matters the moment there is something worth syncing, and demanding one from
/// somebody who has not yet decided to use the app is asking a stranger to commit.
///
/// Whichever window asked steps aside while this is up and returns afterwards, so
/// the screen never holds two things competing for the same decision. On success
/// the action that raised it completes on its own — the press the user already made
/// is not thrown away and asked for again.
///
/// Dismissing it is always allowed. The app keeps tracking locally, and the first
/// successful sign-in claims that history, because everything local is already
/// dirty.
struct SignInView: View {
    @ObservedObject var auth: AuthService
    /// Called once there is a session, so the app can put its tray item up.
    var onSignedIn: () -> Void
    /// Offered only when the API cannot be reached at all.
    var onContinueOffline: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var mode: Mode = .signIn
    @State private var error: String?
    @State private var offlineOffered = false
    /// Seconds left on the resend cooldown, recomputed on the tick rather than
    /// decremented, so a sleeping laptop resumes with the right number.
    @State private var resendSeconds = 0

    private let countdown = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

    /// Only the Google route hands the flow to a browser. Saying so during an email
    /// sign-up would describe something that is not happening — there is no browser,
    /// and the wait is one request this app is holding open.
    private var isWaitingForBrowser: Bool {
        auth.state == .signingIn(via: .browser)
    }

    /// The account that has just been signed into, while its history question is
    /// unanswered. Nil at every other moment.
    private var confirmingTransferAs: String? {
        if case .needsTransferConfirmation(let email) = auth.state { return email }
        return nil
    }

    /// The address a code has gone to, while it is waiting to be typed back.
    private var awaitingCodeFor: String? {
        if case .awaitingCode(let email) = auth.state { return email }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            if let email = confirmingTransferAs {
                transferConfirmation(as: email)
            } else if let email = awaitingCodeFor {
                codeEntry(for: email)
            } else {
                form
            }
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

            if isWaitingForBrowser {
                // Replaces the buttons only while the browser has the flow, so
                // nothing looks clickable while it cannot be clicked. The email
                // route keeps its buttons — it is waiting on one request, and the
                // primary says so itself.
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

    // MARK: Code entry

    /// The design's "Check your email", with the code field it did not have.
    ///
    /// The design specified a sign-in link, so the screen was purely informational —
    /// a tick, a sentence, "Use another email" and a resend countdown. The structure
    /// and the copy carry over unchanged; only the field and its primary are new, and
    /// they sit where the link's absence left a gap.
    private func codeEntry(for email: String) -> some View {
        VStack(alignment: .center, spacing: Space.x3l) {
            VStack(spacing: Space.m) {
                CheckMark()
                VStack(spacing: Space.s) {
                    Text("Check your email")
                        .font(Type.controlLarge.weight(.medium))
                        .foregroundStyle(Palette.fg)
                    // The address is repeated back because a typo in it is the
                    // likeliest reason no mail arrives, and it is the one mistake the
                    // person can see from here — so it is the one part of the sentence
                    // lifted out of the muted grey, as the design has it.
                    Text("We sent a code to ")
                        .foregroundStyle(Palette.fgMuted)
                        + Text(email).foregroundStyle(Palette.fg)
                        + Text(". It expires in \(expiryPhrase).")
                        .foregroundStyle(Palette.fgMuted)
                }
                .font(Type.small)
                .multilineTextAlignment(.center)
                // The design holds this sentence to a narrow column rather than the
                // full panel width, which is what keeps it reading as a caption.
                .frame(maxWidth: 250)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Space.l) {
                TextField("000000", text: $code)
                    .textFieldStyle(.plain)
                    .font(Type.signupCode)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.fg)
                    .disabled(isBusy)
                    .onSubmit { if canSubmitCode { submitCode() } }
                    .onChange(of: code) { _, entered in
                        // Digits only, six of them. People paste the code out of the
                        // mail with a space or a stray newline attached, and a field
                        // that silently rejects that looks broken.
                        let digits = entered.filter(\.isNumber)
                        let trimmed = String(digits.prefix(6))
                        if trimmed != entered { code = trimmed }
                        // Typing the last digit submits. Nobody wants to reach for a
                        // button after entering a code they just read.
                        if trimmed.count == 6, !isBusy { submitCode() }
                    }
                    .padding(.vertical, Space.l)
                    .background(Palette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 1)
                    )

                if let message = auth.codeError {
                    Text(message)
                        .font(Type.meta)
                        .foregroundStyle(Palette.breakColor)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: submitCode) {
                    Text(isBusy ? "Checking…" : "Continue")
                        .font(Type.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.l)
                }
                .buttonStyle(.plain)
                .background(canSubmitCode ? Palette.accent : Palette.hover)
                .foregroundStyle(canSubmitCode ? Palette.surface : Palette.fgFaint)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .disabled(!canSubmitCode)
                .animation(.easeOut(duration: 0.18), value: canSubmitCode)
            }

            // Two quiet pills side by side, as the design draws them. Deliberately not
            // `.buttonStyle(.link)`: that paints the system's blue, which is not in
            // the palette and reads as a web link dropped into a native panel.
            HStack(spacing: Space.m) {
                Button {
                    code = ""
                    auth.useAnotherEmail()
                } label: {
                    Text("Use another email")
                        .font(Type.small)
                        .foregroundStyle(Palette.fgMuted)
                        .padding(.horizontal, Space.xl)
                        .padding(.vertical, Space.s)
                }
                .buttonStyle(.plain)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )

                if resendSeconds > 0 {
                    // Counts down rather than disabling silently, so the wait reads as
                    // a rule rather than a broken button. No border: it is not a
                    // control yet, and drawing one would invite the click it refuses.
                    Text(Self.resendLabel(resendSeconds))
                        .font(Type.small.monospacedDigit())
                        .foregroundStyle(Palette.fgFaint)
                        .padding(.horizontal, Space.xl)
                        .padding(.vertical, Space.s)
                } else {
                    Button {
                        code = ""
                        Task { await auth.resendCode() }
                    } label: {
                        Text("Resend")
                            .font(Type.small)
                            .foregroundStyle(Palette.fgMuted)
                            .padding(.horizontal, Space.xl)
                            .padding(.vertical, Space.s)
                    }
                    .buttonStyle(.plain)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 1)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, Space.x5l)
        .padding(.top, Space.x4l)
        .padding(.bottom, Space.x5l)
        .onReceive(countdown) { _ in refreshResendCountdown() }
        .onAppear { refreshResendCountdown() }
    }

    private var canSubmitCode: Bool { code.count == 6 && !isBusy }

    /// "10 minutes", from whatever the server said — never a number written here.
    ///
    /// The lifetime is a deployment setting, so the only honest source is the
    /// response. Falling back to the plain noun rather than a guess: a screen with no
    /// figure is vague, a screen with the wrong figure is a lie somebody acts on.
    private var expiryPhrase: String {
        guard let seconds = auth.codeExpiresIn else { return "a few minutes" }
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// M:SS, so the wait keeps its shape if the cooldown is ever set past a minute.
    private static func resendLabel(_ seconds: Int) -> String {
        "Resend in \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func submitCode() {
        let entered = code
        Task { await auth.verifyCode(entered) }
    }

    private func refreshResendCountdown() {
        guard let at = auth.resendAvailableAt else { resendSeconds = 0; return }
        resendSeconds = max(0, Int(at.timeIntervalSinceNow.rounded(.up)))
    }

    // MARK: Transfer

    /// Asked once, in the window rather than a dialog, and only when this machine's
    /// history belongs to an account other than the one that just signed in.
    ///
    /// The wording avoids "merge" on purpose: the hours move wholesale to the new
    /// account, they are not interleaved with what is already there. It also avoids
    /// promising that the previous owner keeps everything, because anything this
    /// machine never managed to push exists nowhere else.
    private func transferConfirmation(as email: String) -> some View {
        VStack(alignment: .leading, spacing: Space.x3l) {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("This machine's history belongs to another account")
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Palette.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text("""
                    Continuing as \(email) moves every day and segment tracked on this \
                    Mac into that account. Nothing here is deleted, and whatever the \
                    other account already synced stays in it.
                    """)
                    .font(Type.small)
                    .foregroundStyle(Palette.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                auth.confirmTransfer()
            } label: {
                Text("Move my history over")
                    .font(Type.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.l)
            }
            .buttonStyle(.plain)
            .background(Palette.accent)
            .foregroundStyle(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            Button {
                error = nil
                password = ""
                auth.cancelTransfer()
            } label: {
                Text("Cancel")
                    .font(Type.body)
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

    /// Lit while it is working as well as while it is pressable. A control that has
    /// just been pressed and is doing something must not look like one that has been
    /// switched off — greying it out is how the disabled state reads.
    private var primaryIsLit: Bool { canSubmit || isBusy }

    private var primaryButton: some View {
        Button(action: submit) {
            ZStack {
                // The label keeps its place in the layout while hidden, so the
                // button does not change height under the pointer that pressed it.
                Text(mode == .signUp ? "Create account" : "Continue")
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Palette.surface)
                }
            }
            .font(Type.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
        }
        .buttonStyle(.plain)
        .background(primaryIsLit ? Palette.accent : Palette.hover)
        .foregroundStyle(primaryIsLit ? Palette.surface : Palette.fgFaint)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .disabled(!canSubmit)
        .animation(.easeOut(duration: 0.18), value: primaryIsLit)
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
        .foregroundStyle(isBusy ? Palette.fgFaint : Palette.fg)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        // It used to be removed from the screen while anything was in flight. Now
        // that it stays up during an email sign-up it has to refuse the press
        // itself, or a second flow starts on top of the first.
        .disabled(isBusy)
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

/// The tick that heads the code screen, from the design's "Check your email".
///
/// Drawn rather than an SF Symbol so it matches the design's proportions — a thin
/// ring with a check inset well inside it, which `checkmark.circle` does not give.
/// Drawn in `Palette.work`, the running-timer green, because that is the colour the
/// design gives it. `Palette.accent` is near-white in dark and turns the ring into a
/// washed-out echo of the header's own mark directly above it.
private struct CheckMark: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Palette.work, lineWidth: 1.8)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addLine(to: CGPoint(x: 4.5, y: 9.5))
                path.addLine(to: CGPoint(x: 13, y: 0))
            }
            .stroke(Palette.work, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .frame(width: 13, height: 9.5)
        }
        .frame(width: 38, height: 38)
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
