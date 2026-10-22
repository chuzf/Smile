import SwiftUI
import UIKit

/// 整窗口隐私遮罩：用独立的高层级 UIWindow 承载，能盖住 sheet / 全屏页，
/// 也能赶在系统截多任务快照之前显示出来
@MainActor
final class PrivacyShieldWindow {
    private weak var lockSession: LockSessionManager?
    private var window: UIWindow?

    init(lockSession: LockSessionManager) {
        self.lockSession = lockSession
    }

    func update(visible: Bool) {
        if visible {
            guard window == nil, let lockSession, let scene = Self.activeScene() else { return }
            let host = UIHostingController(rootView: PrivacyShieldView().environment(lockSession))
            host.view.backgroundColor = UIColor(AppColors.cream)
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            w.rootViewController = host
            w.isHidden = false
            window = w
        } else {
            window?.isHidden = true
            window = nil
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}

private struct PrivacyShieldView: View {
    @Environment(LockSessionManager.self) private var lockSession

    var body: some View {
        ZStack {
            AppColors.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(AppColors.warmOrange)
                Text("加锁内容已隐藏")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                if lockSession.needsReauth {
                    Button {
                        Task { await lockSession.resumeFromShield() }
                    } label: {
                        Text("验证身份以继续")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.warmOrange)

                    Button("返回首页") { lockSession.abandonShield() }
                        .font(.system(size: 15))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }
}
