import SwiftUI
import UIKit
import Photos

struct PhotoPreviewView: View {
    let assets: [PHAsset]
    let initialIndex: Int
    @Binding var selectedIDs: Set<String>   // PHAsset.localIdentifier
    var onConfirm: (UIImage) -> Void        // 当前图直接插入
    var onEdit: (UIImage) -> Void           // 当前图进裁剪
    var onDismiss: () -> Void
    var onConfirmBatch: (() -> Void)?

    @State private var currentIndex: Int
    @State private var images: [Int: UIImage] = [:]

    init(assets: [PHAsset],
         initialIndex: Int,
         selectedIDs: Binding<Set<String>>,
         onConfirm: @escaping (UIImage) -> Void,
         onEdit: @escaping (UIImage) -> Void,
         onDismiss: @escaping () -> Void,
         onConfirmBatch: (() -> Void)? = nil) {
        self.assets = assets
        self.initialIndex = initialIndex
        self._selectedIDs = selectedIDs
        self.onConfirm = onConfirm
        self.onEdit = onEdit
        self.onDismiss = onDismiss
        self.onConfirmBatch = onConfirmBatch
        self._currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 使用 UIPageViewController 实现，页面宽度严格等于容器宽度，
            // 图片以 aspectFit 居中，滑动停止后不会偏移或露出相邻图。
            PhotoPager(assets: assets, currentIndex: $currentIndex) { idx, img in
                images[idx] = img
            }
            .ignoresSafeArea()

            // 顶栏/底栏 overlay 在图片上方
            VStack(spacing: 0) {
                HStack {
                    backButton()
                    Spacer()
                    checkButton()
                }
                .frame(height: 56)
                .background(Color.black.opacity(0.3))

                Spacer()

                bottomBar()
                    .frame(height: 64)
                    .background(Color.black.opacity(0.3))
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder private func backButton() -> some View {
        Button(action: onDismiss) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .padding()
        }
    }

    @ViewBuilder private func checkButton() -> some View {
        if let asset = currentAsset {
            let id = asset.localIdentifier
            let checked = selectedIDs.contains(id)
            Button {
                if checked { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .foregroundStyle(checked ? Color.blue : Color.white)
                    .padding()
            }
        }
    }

    @ViewBuilder private func bottomBar() -> some View {
        HStack {
            if canEdit {
                Button("编辑") {
                    guard let img = images[currentIndex] else { return }
                    onEdit(img)
                }
                .foregroundStyle(.white)
            }
            Spacer()
            let isMultiSelected = selectedIDs.count > 1
            Button(isMultiSelected ? "确定（\(selectedIDs.count)）" : "确定") {
                if isMultiSelected {
                    if let confirmBatch = onConfirmBatch {
                        confirmBatch()
                    } else {
                        assertionFailure("onConfirmBatch must be provided when multi-selection is possible")
                        guard let img = images[currentIndex] else { return }
                        onConfirm(img)
                    }
                } else {
                    guard let img = images[currentIndex] else { return }
                    onConfirm(img)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Helpers

    private var currentAsset: PHAsset? {
        guard !assets.isEmpty, currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    private var canEdit: Bool {
        guard let asset = currentAsset else { return false }
        let id = asset.localIdentifier
        return selectedIDs.isEmpty || (selectedIDs.count == 1 && selectedIDs.contains(id))
    }
}

// MARK: - PhotoPager (UIPageViewController wrapper)

/// 包装 UIPageViewController 做全屏图片翻页。相比 SwiftUI 的 TabView(.page)，
/// 页面宽度严格等于容器宽度，滑动停止后图片始终居中、不会露出相邻图。
private struct PhotoPager: UIViewControllerRepresentable {
    let assets: [PHAsset]
    @Binding var currentIndex: Int
    var onImageLoaded: (Int, UIImage) -> Void

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
        if let initial = context.coordinator.makeImageVC(index: currentIndex) {
            pager.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // 仅当外部修改了 currentIndex（非滑动触发）时才同步页面，避免反馈循环。
        guard let shown = pager.viewControllers?.first as? ImagePageVC,
              shown.index != currentIndex,
              let target = context.coordinator.makeImageVC(index: currentIndex) else { return }
        let direction: UIPageViewController.NavigationDirection = currentIndex > shown.index ? .forward : .reverse
        pager.setViewControllers([target], direction: direction, animated: false)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager

        init(_ parent: PhotoPager) { self.parent = parent }

        func makeImageVC(index: Int) -> ImagePageVC? {
            guard index >= 0, index < parent.assets.count else { return nil }
            return ImagePageVC(index: index, asset: parent.assets[index]) { [weak self] img in
                self?.parent.onImageLoaded(index, img)
            }
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? ImagePageVC else { return nil }
            return makeImageVC(index: current.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? ImagePageVC else { return nil }
            return makeImageVC(index: current.index + 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed, let current = pvc.viewControllers?.first as? ImagePageVC else { return }
            parent.currentIndex = current.index
        }
    }
}

// MARK: - ImagePageVC

/// 单页图片视图控制器：一个 aspectFit 的 UIImageView，自动居中。
private final class ImagePageVC: UIViewController {
    let index: Int
    private let asset: PHAsset
    private let onLoaded: (UIImage) -> Void
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var requestID: PHImageRequestID?

    init(index: Int, asset: PHAsset, onLoaded: @escaping (UIImage) -> Void) {
        self.index = index
        self.asset = asset
        self.onLoaded = onLoaded
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        loadImage()
    }

    deinit {
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
    }

    private func loadImage() {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: opts
        ) { [weak self] img, info in
            guard let self, let img else { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            DispatchQueue.main.async {
                self.imageView.image = img
                if !isDegraded {
                    self.spinner.stopAnimating()
                    self.onLoaded(img)
                }
            }
        }
    }
}
