import SwiftUI

struct ClipboardInspectorView: View {
    @ObservedObject var viewModel: ClipboardInspectorViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                mainContent
                overlayContent
            }
            .navigationTitle("剪貼簿檢查")
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    viewModel.onBecomeActive()
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 24) {
            if viewModel.isAnalyzing {
                ProgressView("正在分析剪貼簿...")
                    .padding()
            } else {
                switch viewModel.detectionResult {
                case .noMatch:
                    SafeStatusView()

                case .redacted:
                    RedactedSuccessView {
                        viewModel.skipRedact()
                    }

                case .presenceMatch, .kvMatch:
                    // Handled by overlayContent
                    EmptyView()
                }
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch viewModel.detectionResult {
        case .kvMatch(let keywords, let redactedText):
            ConfirmRedactView(
                keywords: keywords,
                redactedText: redactedText,
                onConfirm: {
                    viewModel.confirmRedact(
                        redactedText: redactedText,
                        hitKeywords: keywords
                    )
                },
                onSkip: { viewModel.skipRedact() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))

        case .presenceMatch(let keywords):
            PresenceWarningView(
                keywords: keywords,
                onDismiss: { viewModel.skipRedact() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))

        default:
            EmptyView()
        }
    }
}

// MARK: - Safe Status View

struct SafeStatusView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("剪貼簿內容安全")
                .font(.title2)
                .fontWeight(.semibold)

            Text("目前無偵測到敏感關鍵字")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Redacted Success View

struct RedactedSuccessView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("遮罩完成")
                .font(.title2)
                .fontWeight(.semibold)

            Text("剪貼簿已取代為遮罩後內容")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("請切回目標 App，以任意方式貼上。\n（Command+V / 長按 → 貼上 均有效）")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Button(action: onDone) {
                Text("完成")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal)
    }
}
