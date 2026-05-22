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
                if !viewModel.entries.isEmpty {
                    Button(role: .destructive, action: viewModel.clearEntries) {
                        Label("清除所有記錄", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("遮罩記錄")
            .overlay {
                if viewModel.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("尚無記錄")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("成功遮罩的剪貼簿內容會顯示在此")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
        }
        .task { await viewModel.load() }
    }
}
