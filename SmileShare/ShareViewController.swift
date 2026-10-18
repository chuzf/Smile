import UIKit
import UniformTypeIdentifiers

/// 系统分享面板中的「微笑储蓄罐」：把照片原样复制进 App Group 收件箱，然后唤起主 App 进入编辑。
/// 只复制文件、不解码图片，避免触碰扩展约 120MB 的内存上限。
final class ShareViewController: UIViewController {
    /// 扩展自定义错误码（用户主动取消使用 NSCocoaErrorDomain / NSUserCancelledError）
    private enum ErrorCode: Int {
        case noUsablePhotos = 1
        case saveFailed = 2
    }

    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let okButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var inbox: SharedInbox?
    /// 正在写入、尚未提交的 batch；提交或丢弃后置空
    private var pending: SharedInbox.PendingBatch?
    private var cancelled = false
    private var started = false
    /// 保证 completeRequest / cancelRequest 只调用一次
    private var isDone = false

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        // 必须在 init 中设置，viewDidLoad 时呈现方式已确定；否则半透明背景 + 居中卡片无法按预期显示
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 在 viewDidAppear 中启动：openMainApp 依赖视图已在 window 中，responder chain 才能走到 UIApplication
        guard !started else { return }
        started = true
        Task { await handleShare() }
    }

    // MARK: - Flow

    @MainActor
    private func handleShare() async {
        guard let inbox = SharedInbox.production(),
              let batch = try? inbox.beginBatch() else {
            showMessage("无法保存照片，请稍后重试", cancelCode: .saveFailed)
            return
        }
        self.inbox = inbox
        self.pending = batch

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        var saved = 0
        for provider in providers {
            if await Self.store(provider, into: batch, index: saved + 1) { saved += 1 }
            // 用户已取消：batch 已在 cancelTapped 中丢弃，不提交、不唤起主 App
            if cancelled { return }
        }

        guard saved > 0 else {
            inbox.discard(batch)
            pending = nil
            showMessage("没有可用的照片", cancelCode: .noUsablePhotos)
            return
        }
        pending = nil
        cancelButton.isHidden = true
        guard (try? inbox.commit(batch)) != nil else {
            inbox.discard(batch)
            showMessage("无法保存照片，请稍后重试", cancelCode: .saveFailed)
            return
        }

        if await openMainApp() {
            finish()
        } else {
            showMessage("已收到 \(saved) 张照片，请手动打开微笑储蓄罐继续编辑", cancelCode: nil)
        }
    }

    /// 依次尝试：原始文件 → 原始数据 → UIImage 缩小后转 JPEG
    private static func store(_ provider: NSItemProvider, into batch: SharedInbox.PendingBatch, index: Int) async -> Bool {
        let imageType = UTType.image.identifier

        let copied: Bool = await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
                // url 指向的临时文件在回调返回后即被删除，必须在回调内复制
                guard let url else { cont.resume(returning: false); return }
                cont.resume(returning: (try? batch.addFile(from: url, index: index)) != nil)
            }
        }
        if copied { return true }

        let data: Data? = await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                cont.resume(returning: data)
            }
        }
        if let data, (try? batch.addData(data, ext: preferredExtension(of: provider), index: index)) != nil {
            return true
        }

        // 最后兜底：UIImage 会被完整解码，按长边 4096 缩小后再编码，降低超出内存上限的风险
        let jpeg: Data? = await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                cont.resume(returning: (object as? UIImage).flatMap { downscaledJPEG($0) })
            }
        }
        if let jpeg, (try? batch.addData(jpeg, ext: "jpg", index: index)) != nil {
            return true
        }
        return false
    }

    private static func downscaledJPEG(_ image: UIImage, maxPixelSide: CGFloat = 4096) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longSide = max(pixelWidth, pixelHeight)
        guard longSide > 0 else { return nil }
        let ratio = min(1, maxPixelSide / longSide)
        let target = CGSize(width: (pixelWidth * ratio).rounded(), height: (pixelHeight * ratio).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.jpegData(withCompressionQuality: 0.9) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func preferredExtension(of provider: NSItemProvider) -> String {
        for id in provider.registeredTypeIdentifiers {
            if let type = UTType(id), type.conforms(to: .image), let ext = type.preferredFilenameExtension {
                return ext
            }
        }
        return "jpg"
    }

    /// 扩展没有官方 API 打开宿主 App，以下两种方式均为非官方做法：
    /// - iOS 18+：只有沿 responder chain 找到 UIApplication 调用 `open(_:options:completionHandler:)` 可用；
    /// - iOS 17 及以下：已知可用的是对 responder chain 上的对象 perform `openURL:` selector。
    /// 都失败（或 3 秒内无回调）时返回 false，由调用方提示用户手动打开，并由主 App 的前台检查兜底。
    /// 必须在视图已加入 window 之后调用，否则 responder chain 走不到 UIApplication。
    @MainActor
    private func openMainApp() async -> Bool {
        guard let url = URL(string: "smilejar://share") else { return false }
        if await openViaApplication(url) { return true }
        if #unavailable(iOS 18.0) {
            return openViaLegacySelector(url)
        }
        return false
    }

    @MainActor
    private func openViaApplication(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await withCheckedContinuation { cont in
                    let once = ResumeOnce(cont)
                    // completion 不保证一定回调、也可能不在主线程：统一切回主线程，并以 3 秒超时兜底
                    application.open(url, options: [:]) { ok in
                        DispatchQueue.main.async { once.resume(ok) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.resume(false) }
                }
            }
            responder = current.next
        }
        return false
    }

    @MainActor
    private func openViaLegacySelector(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// 保证 continuation 只 resume 一次；仅在主线程使用，无需加锁
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)

        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false

        spinner.startAnimating()

        messageLabel.text = "正在发送到微笑储蓄罐…"
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        okButton.setTitle("好的", for: .normal)
        okButton.isHidden = true
        okButton.addAction(UIAction { [weak self] _ in
            // 防止重复点击导致多次 completeRequest
            self?.okButton.isEnabled = false
            self?.finish()
        }, for: .touchUpInside)

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addAction(UIAction { [weak self] _ in self?.cancelTapped() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, okButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
    }

    private func cancelTapped() {
        cancelled = true
        cancelButton.isEnabled = false
        if let pending {
            inbox?.discard(pending)
            self.pending = nil
        }
        cancel(with: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    /// cancelCode 非 nil 时 1.5 秒后自动以该错误码取消；为 nil 时显示「好的」按钮由用户确认
    private func showMessage(_ text: String, cancelCode: ErrorCode?) {
        spinner.stopAnimating()
        spinner.isHidden = true
        cancelButton.isHidden = true
        messageLabel.text = text
        if let cancelCode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.cancel(with: NSError(domain: "SmileShare", code: cancelCode.rawValue))
            }
        } else {
            okButton.isHidden = false
        }
    }

    private func finish() {
        guard !isDone else { return }
        isDone = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel(with error: Error) {
        guard !isDone else { return }
        isDone = true
        extensionContext?.cancelRequest(withError: error)
    }
}
