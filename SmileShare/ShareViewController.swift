import UIKit
import UniformTypeIdentifiers

/// 系统分享面板中的「微笑储蓄罐」：把照片原样复制进 App Group 收件箱，然后唤起主 App 进入编辑。
/// 只复制文件、不解码图片，避免触碰扩展约 120MB 的内存上限。
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let okButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        Task { await handleShare() }
    }

    // MARK: - Flow

    @MainActor
    private func handleShare() async {
        guard let inbox = SharedInbox.production(),
              let pending = try? inbox.beginBatch() else {
            showMessage("无法保存照片，请稍后重试", autoCancel: true)
            return
        }

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        var saved = 0
        for provider in providers {
            if await Self.store(provider, into: pending, index: saved + 1) { saved += 1 }
        }

        guard saved > 0 else {
            inbox.discard(pending)
            showMessage("没有可用的照片", autoCancel: true)
            return
        }
        guard (try? inbox.commit(pending)) != nil else {
            inbox.discard(pending)
            showMessage("无法保存照片，请稍后重试", autoCancel: true)
            return
        }

        if await openMainApp() {
            finish()
        } else {
            showMessage("已收到 \(saved) 张照片，请打开微笑储蓄罐继续编辑", autoCancel: false)
        }
    }

    /// 依次尝试：原始文件 → 原始数据 → UIImage 转 JPEG
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

        let jpeg: Data? = await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                cont.resume(returning: (object as? UIImage)?.jpegData(compressionQuality: 0.9))
            }
        }
        if let jpeg, (try? batch.addData(jpeg, ext: "jpg", index: index)) != nil {
            return true
        }
        return false
    }

    private static func preferredExtension(of provider: NSItemProvider) -> String {
        for id in provider.registeredTypeIdentifiers {
            if let type = UTType(id), type.conforms(to: .image), let ext = type.preferredFilenameExtension {
                return ext
            }
        }
        return "jpg"
    }

    /// 扩展没有官方 API 打开宿主 App，这里沿 responder chain 找到 UIApplication 调用 open。
    /// 若未来 iOS 封禁此方式会返回 false，由主 App 的前台检查兜底。
    @MainActor
    private func openMainApp() async -> Bool {
        guard let url = URL(string: "smilejar://share") else { return false }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await withCheckedContinuation { cont in
                    application.open(url, options: [:]) { cont.resume(returning: $0) }
                }
            }
            responder = current.next
        }
        return false
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
        okButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, okButton])
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

    private func showMessage(_ text: String, autoCancel: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        messageLabel.text = text
        if autoCancel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.cancel() }
        } else {
            okButton.isHidden = false
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "SmileShare", code: 0))
    }
}
