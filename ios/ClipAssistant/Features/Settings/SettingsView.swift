import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("監控關鍵字") {
                    KeywordListView(viewModel: viewModel)
                }

                Section("替換 Token") {
                    TextField("預設：***", text: $viewModel.replacementToken)
                        .autocorrectionDisabled()
                        .onChange(of: viewModel.replacementToken) { _, _ in
                            viewModel.hasUnsavedChanges = true
                        }
                }

                Section("監控狀態") {
                    Toggle("暫停監控", isOn: $viewModel.isPaused)
                        .onChange(of: viewModel.isPaused) { _, _ in
                            viewModel.hasUnsavedChanges = true
                        }
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { viewModel.save() }
                        .disabled(!viewModel.hasUnsavedChanges)
                }
            }
        }
    }
}
