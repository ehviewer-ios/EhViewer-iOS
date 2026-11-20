import UIKit
import AVFoundation
import MediaPlayer

/// 音量键翻页。对应 Android `onKeyDown(KEYCODE_VOLUME_UP/DOWN)`。
///
/// iOS 没有音量键事件：激活音频会话后 KVO `outputVolume`，检测到变化即视为按键，
/// 再通过隐藏的 `MPVolumeView` 滑块把音量复位（同时隐藏系统音量 HUD）。
/// 默认关闭（`EhSettings.volumePage` 默认 false），副作用在阅读设置中说明。
@MainActor
final class ReaderVolumeKeyObserver: NSObject {
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    private let volumeView = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
    private var observation: NSKeyValueObservation?
    private var originalVolume: Float = 0.5
    private var baseline: Float = 0.5
    private var attached = false

    func attach(to view: UIView) {
        guard !attached else { return }
        attached = true
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)

        let session = AVAudioSession.sharedInstance()
        // ambient + mixWithOthers：不打断其他 App 的音频
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        originalVolume = session.outputVolume
        // 尽量不改动用户音量：只有音量在两端（继续按键不会产生变化）时才挪开一格
        baseline = min(max(originalVolume, Self.step), 1 - Self.step)
        if abs(baseline - originalVolume) > 0.001 { setSystemVolume(baseline) }

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.volumeChanged(value) }
        }
    }

    /// 系统音量一格（16 级）
    private static let step: Float = 1.0 / 16

    func detach() {
        guard attached else { return }
        attached = false
        observation?.invalidate()
        observation = nil
        if abs(AVAudioSession.sharedInstance().outputVolume - originalVolume) > 0.001 {
            setSystemVolume(originalVolume)
        }
        let view = volumeView
        // 稍后移除，让复位音量生效
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            view.removeFromSuperview()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func volumeChanged(_ value: Float) {
        guard attached else { return }
        // 自己复位产生的回调
        if abs(value - baseline) < 0.001 { return }
        if value > baseline {
            onVolumeUp?()
        } else {
            onVolumeDown?()
        }
        setSystemVolume(baseline)
    }

    private func setSystemVolume(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // MPVolumeView 的滑块需要异步设置才会生效
        DispatchQueue.main.async {
            slider.value = value
        }
    }
}
