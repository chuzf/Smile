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
    @State private var scrollState = GridScrollState()
    private let maxSelection = 9
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月"
        return f
    }()
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
                    .background(GeometryReader { g in
                        Color.clear.preference(
                            key: GridOffsetKey.self,
                            value: g.frame(in: .named("photoGrid")).minY
                        )
                    })
                }
                // 只写不读：滚动时仅 PhotoScrubber 刷新，网格本身不重算
                .trackScrollOffset(into: scrollState)
                .scrollIndicators(assets.count > 50 ? .hidden : .automatic)
                .overlay {
                    if assets.count > 50 {
                        PhotoScrubber(
                            state: scrollState,
                            rowCount: (assets.count + 2) / 3,
                            rowHeight: cellSize + 2,
                            label: { row in
                                let idx = row * 3
                                guard idx < assets.count, let date = assets[idx].creationDate else { return nil }
                                return Self.monthFormatter.string(from: date)
                            },
                            onJumpToRow: { row in
                                let idx = row * 3
                                guard idx < assets.count else { return }
                                proxy.scrollTo(assets[idx].localIdentifier, anchor: .top)
                            }
                        )
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

private struct GridOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    /// iOS 18+ 用 onScrollGeometryChange；iOS 17 退回到 PreferenceKey 读取内容位置
    @ViewBuilder
    func trackScrollOffset(into state: GridScrollState) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                state.offset = offset
            }
        } else {
            coordinateSpace(name: "photoGrid")
                .onPreferenceChange(GridOffsetKey.self) { state.offset = -$0 }
        }
    }
}

@Observable
private final class GridScrollState {
    /// 网格当前的纵向滚动偏移（向下滚为正）
    var offset: CGFloat = 0
}

/// 快速滚动手柄：滚动时浮现、静止 1.5 秒后隐藏，只有手柄本身响应触摸，
/// 拖动时在左侧显示当前位置的年月。
private struct PhotoScrubber: View {
    let state: GridScrollState
    let rowCount: Int
    let rowHeight: CGFloat
    let label: (Int) -> String?
    let onJumpToRow: (Int) -> Void

    @State private var visible = false
    @State private var dragStartFraction: CGFloat? = nil
    @State private var dragFraction: CGFloat? = nil
    @State private var currentRow: Int? = nil
    @State private var hideTask: Task<Void, Never>? = nil

    private let handleSize = CGSize(width: 50, height: 56)
    private let edgeInset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let viewHeight = geo.size.height
            let travel = max(0, viewHeight - handleSize.height - edgeInset * 2)
            let maxOffset = max(0, CGFloat(rowCount) * rowHeight - 2 - viewHeight)
            let scrollFraction = maxOffset > 0 ? min(max(state.offset / maxOffset, 0), 1) : 0
            let fraction = dragFraction ?? scrollFraction

            HStack(spacing: 8) {
                if dragFraction != nil, let row = currentRow, let text = label(row) {
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .allowsHitTesting(false)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(white: 0.25))
                    .frame(width: handleSize.width, height: handleSize.height)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        // 用全局坐标的位移量：手柄自身在移动，局部坐标会产生反馈
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartFraction == nil {
                                    dragStartFraction = scrollFraction
                                    hideTask?.cancel()
                                    visible = true
                                }
                                guard travel > 0, let start = dragStartFraction else { return }
                                let f = min(max(start + value.translation.height / travel, 0), 1)
                                dragFraction = f
                                let row = f >= 1
                                    ? rowCount - 1
                                    : min(Int((f * maxOffset / rowHeight).rounded()), rowCount - 1)
                                if row != currentRow {
                                    currentRow = row
                                    onJumpToRow(row)
                                }
                            }
                            .onEnded { _ in
                                dragStartFraction = nil
                                dragFraction = nil
                                currentRow = nil
                                scheduleHide()
                            }
                    )
            }
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(y: edgeInset + fraction * travel)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
        }
        .onChange(of: state.offset) { old, new in
            guard abs(new - old) > 0.5 else { return }
            if !visible {
                withAnimation(.easeOut(duration: 0.2)) { visible = true }
            }
            if dragStartFraction == nil { scheduleHide() }
        }
        .onDisappear { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, dragStartFraction == nil else { return }
            withAnimation(.easeIn(duration: 0.3)) { visible = false }
        }
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
