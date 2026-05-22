import SwiftUI

struct KeywordListView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var newKeyword: String = ""

    var body: some View {
        Group {
            ForEach(viewModel.keywords, id: \.self) { keyword in
                Text(keyword)
            }
            .onDelete { offsets in
                viewModel.removeKeyword(at: offsets)
            }

            HStack {
                TextField("新增關鍵字", text: $newKeyword)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .onSubmit { submitKeyword() }

                Button(action: submitKeyword) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submitKeyword() {
        viewModel.addKeyword(newKeyword)
        newKeyword = ""
    }
}
