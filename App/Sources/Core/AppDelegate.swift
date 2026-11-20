import UIKit

/// 仅用于屏幕方向锁定（阅读器的“竖屏/横屏”设置）
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var orientationMask: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Self.orientationMask }
    }
}
