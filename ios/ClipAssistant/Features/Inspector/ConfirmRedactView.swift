import SwiftUI

struct ConfirmRedactView: View {
    let keywords: [String]
    let redactedText: String
    let onConfirm: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("偵測到敏感關鍵字", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)

            Text("命中關鍵字：\(keywords.joined(separator: ", "))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("遮罩預覽")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(String(redactedText.prefix(200)))
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 12) {
                Button(action: onSkip) {
                    Text("略過")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onConfirm) {
                    Text("取代剪貼簿")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding()
    }
}
