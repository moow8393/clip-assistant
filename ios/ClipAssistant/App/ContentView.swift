import SwiftUI

struct ContentView: View {
    @StateObject private var inspectorVM = ClipboardInspectorViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ClipboardInspectorView(viewModel: inspectorVM)
                .tabItem { Label("檢查", systemImage: "doc.on.clipboard") }

            HistoryView()
                .tabItem { Label("記錄", systemImage: "clock") }

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        // ScenePhase observation at the App level ensures we catch every foreground transition.
        // ClipboardInspectorView also observes scenePhase independently as a safety net.
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                inspectorVM.onBecomeActive()
            }
        }
    }
}
