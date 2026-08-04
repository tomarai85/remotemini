import SwiftUI

/// Spec §2-1 / §5-1. No default host is shown anywhere on this screen -- the
/// placeholder is a bare scheme, not a real or example tailnet address (hard
/// constraint: no hardcoded host in source, not even as a placeholder).
struct KeyEntryView: View {
    @StateObject private var viewModel: KeyEntryViewModel

    init(onSaved: @escaping (Credentials) -> Void) {
        _viewModel = StateObject(wrappedValue: KeyEntryViewModel(onSaved: onSaved))
    }

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $viewModel.baseURLText, prompt: Text("https://"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("keyEntry.baseURL")
                SecureField("API Key", text: $viewModel.apiKeyText)
                    .accessibilityIdentifier("keyEntry.apiKey")
            } footer: {
                if let message = viewModel.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("keyEntry.error")
                }
            }

            Section {
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isChecking {
                        ProgressView()
                    } else {
                        Text("接続")
                    }
                }
                .disabled(viewModel.isChecking || viewModel.baseURLText.isEmpty || viewModel.apiKeyText.isEmpty)
                .accessibilityIdentifier("keyEntry.submit")
            } footer: {
                Text(BuildInfo.line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Remote Mini")
    }
}
