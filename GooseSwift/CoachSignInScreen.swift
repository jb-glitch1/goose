import SwiftUI

struct CoachSignInScreen: View {
  let loginStatus: String
  let errorMessage: String?
  let submit: (String) -> Void

  @State private var apiKeyDraft = ""
  @FocusState private var keyFieldFocused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          Image(systemName: "sparkles")
            .font(.title2.weight(.bold))
            .foregroundStyle(.blue)
            .frame(width: 42, height: 42)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

          Text("Connect Claude")
            .font(.title2.bold())
          Text("Coach streams replies from Anthropic's Claude. Paste your Anthropic API key to connect.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 12) {
          CoachStatusLine(title: "Status", value: loginStatus)

          SecureField("sk-ant-…", text: $apiKeyDraft)
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.go)
            .focused($keyFieldFocused)
            .onSubmit(connect)

          if let errorMessage, !errorMessage.isEmpty {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }

          Button(action: connect) {
            Label("Connect", systemImage: "key.horizontal")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Link(
            "Create a key at console.anthropic.com",
            destination: URL(string: "https://console.anthropic.com/settings/keys")!
          )
          .font(.footnote.weight(.semibold))

          Text("Your key is stored only in this device's Keychain and is sent to Anthropic to stream Coach replies. Coach also sends the question plus bounded local tool output. Usage is billed to your Anthropic account.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
  }

  private func connect() {
    let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return
    }
    keyFieldFocused = false
    submit(trimmed)
    apiKeyDraft = ""
  }
}

private struct CoachStatusLine: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
  }
}
