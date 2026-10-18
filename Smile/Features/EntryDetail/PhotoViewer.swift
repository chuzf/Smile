import SwiftUI
import UIKit

struct PhotoViewerItem: Identifiable {
    let id = UUID()
    let urls: [URL]
    let initialIndex: Int
}

/// 全屏照片查看器：双指/双击缩放，未放大时左右滑动切换、向下拖动关闭，单击切换顶栏
struct PhotoViewer: View {
    let urls: [URL]
    let onClose: () -> Void

    @State private var currentIndex: Int
    @State private var showChrome = true
    @State private var dragOffset: CGFloat = 0

    /// 松手时超过这个位移或速度就关闭
    private let dismissDistance: CGFloat = 120
    private let dismissVelocity: CGFloat = 800

    init(urls: [URL], initialIndex: Int, onClose: @escaping () -> Void) {
        self.urls = urls
        self.onClose = onClose
        _currentIndex = State(initialValue: min(max(initialIndex, 0), max(urls.count - 1, 0)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .opacity(1 - min(dragOffset / 400, 0.6))
                .ignoresSafeArea()

            ZoomablePhotoPager(
                urls: urls,
                currentIndex: $currentIndex,
                onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() } },
                onDismissPan: handleDismissPan
            )
            .offset(y: dragOffset)
            .ignoresSafeArea()

            if showChrome && dragOffset == 0 {
                topBar
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
    }

    private var topBar: some View {
        ZStack {
            Text("\(currentIndex + 1) / \(urls.count)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(Color.black.opacity(0.3))
    }

    private func handleDismissPan(translation: CGFloat, velocity: CGFloat, ended: Bool) {
        guard ended else {
            dragOffset = max(0, translation)
            return
        }
        if translation > dismissDistance || velocity > dismissVelocity {
            onClose()
        } else {
            withAnimation(.spring(duration: 0.25)) { dragOffset = 0 }
        }
    }
}

// MARK: - 翻页

/// UIPageViewController 翻页；每页是可缩放的 UIScrollView。
/// 放大后左右拖动先移动图片，拖到边缘才翻页。
private struct ZoomablePhotoPager: UIViewControllerRepresentable {
    let urls: [URL]
    @Binding var currentIndex: Int
    let onSingleTap: () -> Void
    let onDismissPan: (_ translation: CGFloat, _ velocity: CGFloat, _ ended: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 20]
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .clear
        if let initial = context.coordinator.makePage(index: currentIndex) {
            pager.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ZoomablePhotoPager

        init(_ parent: ZoomablePhotoPager) { self.parent = parent }

        func makePage(index: Int) -> ZoomPhotoPageVC? {
            guard parent.urls.indices.contains(index) else { return nil }
            let page = ZoomPhotoPageVC(index: index, url: parent.urls[index])
            // 回调读取最新的 parent，SwiftUI 重建 representable 后仍然有效
            page.onSingleTap = { [weak self] in self?.parent.onSingleTap() }
            page.onDismissPan = { [weak self] translation, velocity, ended in
                self?.parent.onDismissPan(translation, velocity, ended)
            }
            return page
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ZoomPhotoPageVC else { return nil }
            return makePage(index: page.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ZoomPhotoPageVC else { return nil }
            return makePage(index: page.index + 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed, let page = pvc.viewControllers?.first as? ZoomPhotoPageVC else { return }
            parent.currentIndex = page.index
        }
    }
}

// MARK: - 单页

private final class ZoomPhotoPageVC: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// 查看器读原图；4096 不会缩小 iPhone 原片，只防极端大图
    static let maxPixel = 4096
    static let maxZoom: CGFloat = 4
    static let doubleTapZoom: CGFloat = 2.5

    let index: Int
    private let url: URL
    var onSingleTap: (() -> Void)?
    var onDismissPan: ((CGFloat, CGFloat, Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failureLabel = UILabel()
    private let dismissPan = UIPanGestureRecognizer()
    private var laidOutSize: CGSize = .zero
    private var loadTask: Task<Void, Never>?

    init(index: Int, url: URL) {
        self.index = index
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Self.maxZoom
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        failureLabel.text = "图片无法加载"
        failureLabel.textColor = .lightGray
        failureLabel.font = .systemFont(ofSize: 15)
        failureLabel.isHidden = true
        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failureLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failureLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        scrollView.addGestureRecognizer(dismissPan)

        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.bounds.size != laidOutSize {
            layoutImage()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 翻走后还原，回来时是完整的一张
        scrollView.setZoomScale(1, animated: false)
    }

    private func loadImage() {
        spinner.startAnimating()
        let url = url
        loadTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ImageLoader.downsampled(url: url, maxPixel: Self.maxPixel)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image {
                self.imageView.image = image
                self.layoutImage()
            } else {
                self.failureLabel.isHidden = false
            }
        }
    }

    /// 图片按 aspect fit 放进 scroll view，用 contentInset 居中；放大后不会拖到黑边以外
    private func layoutImage() {
        let bounds = scrollView.bounds.size
        laidOutSize = bounds
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centerImage()
    }

    private func centerImage() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let x = max((bounds.width - content.width) / 2, 0)
        let y = max((bounds.height - content.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    // MARK: 手势

    @objc private func handleSingleTap() { onSingleTap?() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scrollView.bounds.width / Self.doubleTapZoom,
                          height: scrollView.bounds.height / Self.doubleTapZoom)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                          width: size.width, height: size.height)
        scrollView.zoom(to: rect, animated: true)
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).y
        switch gesture.state {
        case .changed:
            onDismissPan?(translation, 0, false)
        case .ended:
            onDismissPan?(translation, gesture.velocity(in: view).y, true)
        case .cancelled, .failed:
            onDismissPan?(0, 0, true)
        default:
            break
        }
    }

    /// 下拉关闭只在未放大、且以竖直向下为主时开始；横向交给翻页
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
        let velocity = dismissPan.velocity(in: view)
        return velocity.y > 0 && velocity.y > abs(velocity.x)
    }
}
