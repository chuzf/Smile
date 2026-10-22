import SwiftUI
import UIKit

/// 整窗口隐私遮罩：用独立的高层级 UIWindow 承载，能盖住 sheet / 全屏页，
/// 也能赶在系统截多任务快照之前显示出来
@MainActor
final class PrivacyShieldWindow {
    private weak var lockSession: LockSessionManager?
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    init(lockSession: LockSessionManager) {
        self.lockSession = lockSession
    }

    func update(visible: Bool) {
        if visible {
            guard window == nil, let lockSession, let scene = Self.activeScene() else { return }
            let host = UIHostingController(rootView: PrivacyShieldView().environment(lockSession))
            host.view.backgroundColor = UIColor(AppColors.cream)
            // 先收起键盘：键盘窗口层级比遮罩高，不收起会浮在遮罩上，打字还会进到后面的输入框
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            w.rootViewController = host
            w.makeKeyAndVisible()
            window = w
        } else {
            window?.isHidden = true
            window = nil
            previousKeyWindow?.makeKey()
            previousKeyWindow = nil
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

// MARK: - 正在展示加锁内容的页面登记

extension View {
    /// 页面在导航栈里（含被 sheet / 全屏页盖住时）且展示加锁内容，离开前台就会盖遮罩
    func displaysLockedContent(_ isLocked: Bool) -> some View {
        modifier(LockedContentMarker(isLocked: isLocked))
    }
}

private struct LockedContentMarker: ViewModifier {
    @Environment(LockSessionManager.self) private var lockSession
    let isLocked: Bool
    // 随页面身份存活：页面被 pop 时才释放，比 onDisappear 可靠（被全屏页盖住时 onDisappear 也会触发）
    @State private var registration = LockedContentRegistration()

    func body(content: Content) -> some View {
        content
            .onAppear { registration.update(isLocked: isLocked, session: lockSession) }
            .onChange(of: isLocked) { _, locked in registration.update(isLocked: locked, session: lockSession) }
    }
}

@MainActor
private final class LockedContentRegistration {
    private let token = UUID()
    private weak var session: LockSessionManager?

    func update(isLocked: Bool, session: LockSessionManager) {
        self.session = session
        if isLocked {
            session.beginDisplayingLockedContent(token)
        } else {
            session.endDisplayingLockedContent(token)
        }
    }

    deinit {
        let token = token
        let session = session
        Task { @MainActor in session?.endDisplayingLockedContent(token) }
    }
}
