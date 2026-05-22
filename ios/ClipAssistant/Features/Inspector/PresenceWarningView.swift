import SwiftUI

struct PresenceWarningView: View {
    let keywords: [String]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("包含敏感關鍵字，但無法自動遮罩", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
                .font(.headline)

            Text("命中關鍵字：\(keywords.joined(separator: ", "))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("無法偵測到 key: value 格式。\n請手動檢查後再貼上。")
                .font(.body)

            Button(action: onDismiss) {
                Text("了解")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding()
    }
}
