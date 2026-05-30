import SwiftUI
import Photos

struct PhotoPreviewView: View {
    let assets: [PHAsset]
    let initialIndex: Int
    @Binding var selectedIDs: Set<String>   // PHAsset.localIdentifier
    var onConfirm: (UIImage) -> Void        // 当前图直接插入
    var onEdit: (UIImage) -> Void           // 当前图进裁剪
    var onDismiss: () -> Void

    @State private var currentIndex: Int = 0
    @State private var images: [Int: UIImage] = [:]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pageView
        }
        .overlay(alignment: .topLeading,  content: backButton)
        .overlay(alignment: .topTrailing, content: checkButton)
        .overlay(alignment: .bottom,      content: bottomBar)
        .onAppear {
            currentIndex = initialIndex
            loadImage(at: initialIndex)
        }
        .onChange(of: currentIndex) { _, idx in loadImage(at: idx) }
    }

    // MARK: - Page view

    private var pageView: some View {
        TabView(selection: $currentIndex) {
            ForEach(assets.indices, id: \.self) { idx in
                SwiftUI.Group {
                    if let img = images[idx] {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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
        let id = currentAsset.localIdentifier
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
            Button("确定") {
                guard let img = images[currentIndex] else { return }
                onConfirm(img)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }

    // MARK: - Helpers

    private var currentAsset: PHAsset { assets[currentIndex] }

    private var canEdit: Bool {
        let id = currentAsset.localIdentifier
        return selectedIDs.isEmpty || (selectedIDs.count == 1 && selectedIDs.contains(id))
    }

    private func loadImage(at index: Int) {
        guard index < assets.count, images[index] == nil else { return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false
        PHImageManager.default().requestImage(
            for: assets[index],
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: opts
        ) { img, _ in
            guard let img else { return }
            DispatchQueue.main.async { images[index] = img }
        }
    }
}
