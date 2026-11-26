import SwiftUI
import StaveCore

/// What the sign-in sheet ended with, set by `AuthSheet` before the sheet comes down (a flag, not a return code: `AppDelegate.quit()` and a
/// hidden tab end sheets too). `isUserChoice` false: the sheet was taken down, not answered.
@MainActor
final class AuthSheetResult {
    var answer: AuthAnswer?
    var isUserChoice = false
}

/// The HTTP sign-in sheet (decision 15): "‹host› wants you to sign in", the site's realm in its own words, a user name and a password.
/// Layout and focus only; every string and rule is StaveCore's (`AuthText`). Stave stores nothing: `onFinish` gets the typed answer, or nil
/// for Cancel, and the fields go with the sheet.
struct AuthSheet: View {
    let challenge: AuthChallenge
    let onFinish: (AuthAnswer?) -> Void

    @State private var user = ""
    @State private var password = ""
    @FocusState private var userFocused: Bool

    private var detail: String { AuthText.detail(for: challenge) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AuthText.title(for: challenge))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fields
            buttons
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { userFocused = true }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(AuthText.userNameLabel, text: $user)
                .textContentType(.username)
                .focused($userFocused)
                .accessibilityLabel(AuthText.userNameLabel)
            SecureField(AuthText.passwordLabel, text: $password)
                .textContentType(.password)
                .accessibilityLabel(AuthText.passwordLabel)
                .onSubmit(signIn)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(AuthText.cancelButton) { onFinish(nil) }
                .keyboardShortcut(.cancelAction)
            Button(AuthText.signInButton, action: signIn)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func signIn() {
        onFinish(AuthAnswer(user: user, password: password))
    }
}
