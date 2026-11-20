import SwiftUI

@main
struct EhViewerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        BackgroundDownloads.register(model: model)
        SearchFieldCaret.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: BackgroundDownloads.didEnterBackground()
            case .active: BackgroundDownloads.willEnterForeground()
            case .inactive: BackgroundDownloads.willResignActive()
            default: break
            }
        }
    }
}
