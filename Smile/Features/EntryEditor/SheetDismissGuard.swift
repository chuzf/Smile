import SwiftUI
import UIKit

extension View {
    /// 所在 sheet 被 `interactiveDismissDisabled` 挡住下滑关闭时，回调 `onAttempt`（用来弹出保存/放弃提示）
    func onSheetDismissAttempt(_ onAttempt: @escaping () -> Void) -> some View {
        background(SheetDismissGuard(onAttempt: onAttempt).frame(width: 0, height: 0))
    }
}

private struct SheetDismissGuard: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.proxy.onAttempt = onAttempt
        controller.install()
    }

    final class Controller: UIViewController {
        let proxy = DelegateProxy()

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        /// 找到所在 sheet 的 presentationController，把代理换成转发代理；SwiftUI 原有代理的行为全部保留
        func install() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard root.presentingViewController != nil,
                  let presentation = root.presentationController,
                  presentation.delegate !== proxy else { return }
            proxy.original = presentation.delegate
            presentation.delegate = proxy
        }
    }

    /// 只额外处理「尝试下滑关闭」，其余代理方法转发给 SwiftUI 原来的代理
    final class DelegateProxy: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var original: UIAdaptivePresentationControllerDelegate?
        var onAttempt: () -> Void = {}

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            original?.presentationControllerDidAttemptToDismiss?(presentationController)
            onAttempt()
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
