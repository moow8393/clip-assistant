import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.hitKeywords.joined(separator: ", "))
                                .font(.headline)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("遮罩記錄")
            .toolbar {
                if !viewModel.entries.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("清除") {
                            Task { await viewModel.clear() }
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if viewModel.entries.isEmpty {
                    ContentUnavailableView(
                        "尚無記錄",
                        systemImage: "clock.badge.checkmark",
                        description: Text("成功遮罩的剪貼簿內容會顯示在此")
                    )
                }
            }
        }
        .task { await viewModel.load() }
    }
}
