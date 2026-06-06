import SwiftUI
import UIKit
import Photos

struct PhotoLibraryPickerView: View {
    var onSelect: ([UIImage]) -> Void
    var onCancel: () -> Void

    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var assets: [PHAsset] = []
    @State private var selectedIDs: Set<String> = []
    @State private var previewIndex: Int? = nil
    @State private var editImage: UIImage? = nil
    private let maxSelection = 9
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationView {
            SwiftUI.Group {
                switch authStatus {
                case .authorized, .limited:
                    gridView
                case .denied, .restricted:
                    deniedView
                default:
                    ProgressView()
                }
            }
            .navigationTitle("照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !selectedIDs.isEmpty {
                        Button("确定（\(selectedIDs.count)）") { confirmSelection() }
                    }
                }
            }
        }
        .onAppear { checkPermission() }
        .fullScreenCover(isPresented: Binding(
            get: { previewIndex != nil },
            set: { if !$0 { previewIndex = nil } }
        )) {
            if let idx = previewIndex {
                PhotoPreviewView(
                    assets: assets,
                    initialIndex: idx,
                    selectedIDs: $selectedIDs,
                    onConfirm: { img in
                        previewIndex = nil
                        onSelect([img])
                    },
                    onEdit: { img in
                        previewIndex = nil
                        editImage = img
                    },
                    onDismiss: { previewIndex = nil },
                    onConfirmBatch: {
                        previewIndex = nil
                        confirmSelection()
                    }
                )
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { editImage != nil },
            set: { if !$0 { editImage = nil } }
        )) {
            if let img = editImage {
                PhotoCropView(image: img) { cropped in
                    editImage = nil
                    onSelect([cropped])
                } onCancel: {
                    editImage = nil
                }
            }
        }
    }

    // MARK: - Grid

    private var gridView: some View {
        GeometryReader { geo in
            let cellSize = (geo.size.width - 4) / 3
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                            let id = asset.localIdentifier
                            ThumbnailCell(
                                asset: asset,
                                size: cellSize,
                                isSelected: selectedIDs.contains(id),
                                selectionDisabled: !selectedIDs.contains(id) && selectedIDs.count >= maxSelection,
                                onTap: { previewIndex = idx },
                                onToggleSelect: {
                                    if selectedIDs.contains(id) {
                                        selectedIDs.remove(id)
                                    } else if selectedIDs.count < maxSelection {
                                        selectedIDs.insert(id)
                                    }
                                }
                            )
                            .id(id)
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if assets.count > 50 {
                        PhotoScrubber(totalCount: assets.count) { idx in
                            guard idx < assets.count else { return }
                            proxy.scrollTo(assets[idx].localIdentifier, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Permission denied

    private var deniedView: some View {
        VStack(spacing: 16) {
            Text("无法访问相册")
                .font(.headline)
            Text("请在「设置 → 隐私 → 照片」中允许访问")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func checkPermission() {
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    authStatus = status
                    if status == .authorized || status == .limited { fetchAssets() }
                }
            }
        } else if authStatus == .authorized || authStatus == .limited {
            fetchAssets()
        }
    }

    private func fetchAssets() {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: opts)
        var fetched: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        DispatchQueue.main.async { assets = fetched }
    }

    private func confirmSelection() {
        let ordered = assets.filter { selectedIDs.contains($0.localIdentifier) }
        guard !ordered.isEmpty else { return }

        var loaded: [Int: UIImage] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        // Track which indices have already called group.leave() to guarantee
        // exactly one leave() per enter(), even when the callback fires multiple
        // times (e.g. degraded preview + final for iCloud photos).
        var completedIndices = Set<Int>()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isSynchronous = false
        opts.isNetworkAccessAllowed = true

        for (i, asset) in ordered.enumerated() {
            group.enter()
            PHImageManager.default().requestImage(
                for: asset, targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit, options: opts
            ) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }  // wait for final result
                var shouldLeave = false
                lock.lock()
                if !completedIndices.contains(i) {
                    completedIndices.insert(i)
                    if let img { loaded[i] = img }
                    shouldLeave = true
                }
                lock.unlock()
                if shouldLeave { group.leave() }
            }
        }

        group.notify(queue: .main) {
            let imgs = (0..<ordered.count).compactMap { loaded[$0] }
            self.onSelect(imgs)
        }
    }
}

// MARK: - PhotoScrubber

private struct PhotoScrubber: View {
    let totalCount: Int
    let onJump: (Int) -> Void

    @State private var thumbFraction: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let thumbHeight: CGFloat = 30
            let travelHeight = max(0, trackHeight - thumbHeight)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(white: 0.7).opacity(0.5))
                    .frame(width: 5)
                    .frame(maxHeight: .infinity)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.35))
                    .frame(width: 6, height: thumbHeight)
                    .offset(y: thumbFraction * travelHeight)
            }
            .frame(width: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let fraction = travelHeight > 0 ? max(0, min(1, value.location.y / travelHeight)) : 0
                        thumbFraction = fraction
                        let idx = min(Int(fraction * CGFloat(totalCount)), max(0, totalCount - 1))
                        onJump(idx)
                    }
            )
        }
        .frame(width: 28)
    }
}

// MARK: - ThumbnailCell

private struct ThumbnailCell: View {
    let asset: PHAsset
    let size: CGFloat
    let isSelected: Bool
    let selectionDisabled: Bool
    let onTap: () -> Void
    let onToggleSelect: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SwiftUI.Group {
                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: size, height: size)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            Button {
                onToggleSelect()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        isSelected ? Color.blue :
                        selectionDisabled ? Color.white.opacity(0.3) : Color.white
                    )
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .padding(6)
            }
        }
        .onAppear { load() }
        .onDisappear { cancel() }
    }

    private func load() {
        guard size > 0 else { return }
        let id = asset.localIdentifier
        if let cached = ThumbnailCache.shared.get(id) {
            thumbnail = cached
            return
        }
        let px = size * displayScale
        let targetSize = CGSize(width: px, height: px)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        requestID = PHImageManager.default().requestImage(
            for: asset, targetSize: targetSize,
            contentMode: .aspectFill, options: opts
        ) { img, info in
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !isCancelled, let img else { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !isDegraded {
                ThumbnailCache.shared.set(img, forKey: id)
            }
            DispatchQueue.main.async { self.thumbnail = img }
        }
    }

    private func cancel() {
        guard let rid = requestID else { return }
        PHImageManager.default().cancelImageRequest(rid)
        requestID = nil
    }
}

// MARK: - ThumbnailCache

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    func get(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ img: UIImage, forKey key: String) {
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale) * 4
        cache.setObject(img, forKey: key as NSString, cost: cost)
    }
}
