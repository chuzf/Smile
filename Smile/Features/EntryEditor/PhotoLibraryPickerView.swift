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
    @State private var thumbnails: [String: UIImage] = [:]

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
                    onDismiss: { previewIndex = nil }
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
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets.indices, id: \.self) { idx in
                    let asset = assets[idx]
                    let id = asset.localIdentifier
                    thumbnailCell(asset: asset, id: id, idx: idx)
                }
            }
        }
    }

    private func thumbnailCell(asset: PHAsset, id: String, idx: Int) -> some View {
        let checked = selectedIDs.contains(id)
        return GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                // Photo — tap to preview
                SwiftUI.Group {
                    if let thumb = thumbnails[id] {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                            .onAppear { loadThumbnail(asset: asset, size: geo.size) }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { previewIndex = idx }

                // Checkmark — tap to select
                Button {
                    if checked { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(checked ? Color.blue : Color.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(6)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
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

    private func loadThumbnail(asset: PHAsset, size: CGSize) {
        guard thumbnails[asset.localIdentifier] == nil else { return }
        let targetSize = CGSize(width: size.width * UIScreen.main.scale,
                                height: size.width * UIScreen.main.scale)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        PHImageManager.default().requestImage(
            for: asset, targetSize: targetSize,
            contentMode: .aspectFill, options: opts
        ) { img, _ in
            guard let img else { return }
            DispatchQueue.main.async { thumbnails[asset.localIdentifier] = img }
        }
    }

    private func confirmSelection() {
        let ordered = assets.filter { selectedIDs.contains($0.localIdentifier) }
        guard !ordered.isEmpty else { return }

        var loaded: [Int: UIImage] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
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
                guard !isDegraded else { return }
                if let img {
                    lock.withLock { loaded[i] = img }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let imgs = (0..<ordered.count).compactMap { loaded[$0] }
            self.onSelect(imgs)
        }
    }
}
