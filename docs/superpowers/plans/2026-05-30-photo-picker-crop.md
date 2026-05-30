# 相册选择器 + 拍摄 + 裁剪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在编辑器工具栏新增"相册"（微信风格自定义选择器）和"拍摄"入口，均支持对单张图片进行裁剪后插入。

**Architecture:** 新增 4 个文件（PhotoCropView、CameraPickerView、PhotoLibraryPickerView、PhotoPreviewView），修改 iOSNoteEditorView 工具栏。相册选择器基于 Photos 框架，网格格子点击进大图预览，大图预览提供"编辑（裁剪）"和"确定（直接插入）"，勾选模式批量插入不裁剪。拍摄走 UIImagePickerController，拍后必过裁剪再插入。

**Tech Stack:** SwiftUI, UIKit (UIImagePickerController), Photos framework (PHAsset/PHImageManager), UIGraphicsImageRenderer

---

## 文件结构

| 操作 | 路径 |
|------|------|
| 新建 | `Smile/Features/EntryEditor/PhotoCropView.swift` |
| 新建 | `Smile/Features/EntryEditor/CameraPickerView.swift` |
| 新建 | `Smile/Features/EntryEditor/PhotoLibraryPickerView.swift` |
| 新建 | `Smile/Features/EntryEditor/PhotoPreviewView.swift` |
| 修改 | `Smile/Features/EntryEditor/iOSNoteEditorView.swift` |
| 新建 | `SmileTests/PhotoCropTests.swift` |

---

## Task 1: PhotoCropView — 裁剪编辑器

**Files:**
- Create: `Smile/Features/EntryEditor/PhotoCropView.swift`
- Create: `SmileTests/PhotoCropTests.swift`

### 1.1 先写裁剪数学逻辑的测试

- [ ] 新建 `SmileTests/PhotoCropTests.swift`：

```swift
import XCTest
@testable import Smile

final class PhotoCropTests: XCTestCase {

    func testCropFullImage() {
        let size = CGSize(width: 200, height: 200)
        let img = makeImage(size: size)
        let imageRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let cropRect  = CGRect(x: 0, y: 0, width: 200, height: 200)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        XCTAssertEqual(result.size.width,  200, accuracy: 1)
        XCTAssertEqual(result.size.height, 200, accuracy: 1)
    }

    func testCropTopLeft() {
        let size = CGSize(width: 200, height: 200)
        let img = makeImage(size: size)
        let imageRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let cropRect  = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        XCTAssertEqual(result.size.width,  100, accuracy: 1)
        XCTAssertEqual(result.size.height, 100, accuracy: 1)
    }

    func testCropCenter() {
        let img = makeImage(size: CGSize(width: 400, height: 400))
        // Image is displayed at x:50, y:50 with 300×300 in view
        let imageRect = CGRect(x: 50, y: 50, width: 300, height: 300)
        // Crop frame covers center 150×150 of that display
        let cropRect  = CGRect(x: 125, y: 125, width: 150, height: 150)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        // 150/300 * 400 = 200
        XCTAssertEqual(result.size.width,  200, accuracy: 2)
        XCTAssertEqual(result.size.height, 200, accuracy: 2)
    }

    func testCropClampsToImageBounds() {
        let img = makeImage(size: CGSize(width: 100, height: 100))
        let imageRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // cropRect extends beyond image
        let cropRect  = CGRect(x: -10, y: -10, width: 200, height: 200)
        let result = PhotoCropView.cropImage(img, cropRect: cropRect, imageRect: imageRect)
        XCTAssertEqual(result.size.width,  100, accuracy: 1)
        XCTAssertEqual(result.size.height, 100, accuracy: 1)
    }

    // MARK: - Helpers
    private func makeImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
```

- [ ] 运行测试，确认编译失败（`PhotoCropView` 和 `cropImage` 尚不存在）：

```bash
xcodebuild test -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/PhotoCropTests 2>&1 | tail -20
```

Expected: build error — `cannot find type 'PhotoCropView'`

---

### 1.2 实现 PhotoCropView

- [ ] 新建 `Smile/Features/EntryEditor/PhotoCropView.swift`：

```swift
import SwiftUI

struct PhotoCropView: View {
    let image: UIImage
    var onCrop: (UIImage) -> Void
    var onCancel: () -> Void

    // Image pan/zoom
    @State private var imgScale: CGFloat = 1
    @State private var lastImgScale: CGFloat = 1
    @State private var imgOffset: CGSize = .zero
    @State private var lastImgOffset: CGSize = .zero

    // Crop frame (view coords)
    @State private var cropRect: CGRect = .zero
    @State private var containerSize: CGSize = .zero
    private let minCrop: CGFloat = 60
    private let handleHit: CGFloat = 32

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    imageLayer(geo: geo)
                    dimmingLayer(geo: geo)
                    cropBorder
                    cornerHandles(geo: geo)
                }
                .contentShape(Rectangle())
                .gesture(imageDrag)
                .simultaneousGesture(imagePinch)
                .onAppear { initCrop(geo.size) }
            }
        }
        .overlay(alignment: .topLeading) {
            Button("取消", action: onCancel)
                .foregroundStyle(.white).padding()
        }
        .overlay(alignment: .bottomTrailing) {
            Button("完成") { commit() }
                .foregroundStyle(.white).padding()
        }
    }

    // MARK: - Image layer

    private func imageLayer(geo: GeometryProxy) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(imgScale)
            .offset(imgOffset)
    }

    // MARK: - Dimming

    private func dimmingLayer(geo: GeometryProxy) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .mask {
                Rectangle()
                    .overlay {
                        Rectangle()
                            .frame(width: cropRect.width, height: cropRect.height)
                            .position(x: cropRect.midX, y: cropRect.midY)
                            .blendMode(.destinationOut)
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .allowsHitTesting(false)
    }

    // MARK: - Crop border

    private var cropBorder: some View {
        Rectangle()
            .stroke(Color.white, lineWidth: 1.5)
            .frame(width: cropRect.width, height: cropRect.height)
            .position(x: cropRect.midX, y: cropRect.midY)
            .allowsHitTesting(false)
    }

    // MARK: - Corner handles

    @ViewBuilder
    private func cornerHandles(geo: GeometryProxy) -> some View {
        Group {
            handle(at: CGPoint(x: cropRect.minX, y: cropRect.minY)) { d in
                stretchCorner(.topLeft, delta: d, geo: geo)
            }
            handle(at: CGPoint(x: cropRect.maxX, y: cropRect.minY)) { d in
                stretchCorner(.topRight, delta: d, geo: geo)
            }
            handle(at: CGPoint(x: cropRect.minX, y: cropRect.maxY)) { d in
                stretchCorner(.bottomLeft, delta: d, geo: geo)
            }
            handle(at: CGPoint(x: cropRect.maxX, y: cropRect.maxY)) { d in
                stretchCorner(.bottomRight, delta: d, geo: geo)
            }
        }
    }

    private func handle(at point: CGPoint, onDrag: @escaping (CGSize) -> Void) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle().size(CGSize(width: handleHit, height: handleHit)))
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { v in onDrag(v.translation) }
            )
    }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func stretchCorner(_ corner: Corner, delta: CGSize, geo: GeometryProxy) {
        var r = cropRect
        switch corner {
        case .topLeft:
            let newX = min(r.maxX - minCrop, r.minX + delta.width)
            let newY = min(r.maxY - minCrop, r.minY + delta.height)
            r = CGRect(x: newX, y: newY, width: r.maxX - newX, height: r.maxY - newY)
        case .topRight:
            let newW = max(minCrop, r.width + delta.width)
            let newY = min(r.maxY - minCrop, r.minY + delta.height)
            r = CGRect(x: r.minX, y: newY, width: newW, height: r.maxY - newY)
        case .bottomLeft:
            let newX = min(r.maxX - minCrop, r.minX + delta.width)
            let newH = max(minCrop, r.height + delta.height)
            r = CGRect(x: newX, y: r.minY, width: r.maxX - newX, height: newH)
        case .bottomRight:
            let newW = max(minCrop, r.width  + delta.width)
            let newH = max(minCrop, r.height + delta.height)
            r = CGRect(x: r.minX, y: r.minY, width: newW, height: newH)
        }
        cropRect = r.clamped(to: CGRect(origin: .zero, size: geo.size))
    }

    // MARK: - Image gestures

    private var imageDrag: some Gesture {
        DragGesture()
            .onChanged { v in
                imgOffset = CGSize(width: lastImgOffset.width + v.translation.width,
                                   height: lastImgOffset.height + v.translation.height)
            }
            .onEnded { _ in lastImgOffset = imgOffset }
    }

    private var imagePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in imgScale = max(1, lastImgScale * v) }
            .onEnded { _ in lastImgScale = imgScale }
    }

    // MARK: - Init & commit

    private func initCrop(_ size: CGSize) {
        containerSize = size
        let side = min(size.width, size.height) * 0.82
        cropRect = CGRect(x: (size.width - side) / 2,
                          y: (size.height - side) / 2,
                          width: side, height: side)
    }

    private func commit() {
        let imageRect = displayRect(containerSize: containerSize)
        let cropped = Self.cropImage(image, cropRect: cropRect, imageRect: imageRect)
        onCrop(cropped)
    }

    private func displayRect(containerSize: CGSize) -> CGRect {
        let aspect = image.size.width / image.size.height
        let containerAspect = containerSize.width / containerSize.height
        let fitW: CGFloat
        let fitH: CGFloat
        if aspect > containerAspect {
            fitW = containerSize.width * imgScale
            fitH = fitW / aspect
        } else {
            fitH = containerSize.height * imgScale
            fitW = fitH * aspect
        }
        let x = (containerSize.width  - fitW) / 2 + imgOffset.width
        let y = (containerSize.height - fitH) / 2 + imgOffset.height
        return CGRect(x: x, y: y, width: fitW, height: fitH)
    }

    // MARK: - Static crop math (testable)

    static func cropImage(_ source: UIImage, cropRect: CGRect, imageRect: CGRect) -> UIImage {
        guard imageRect.width > 0, imageRect.height > 0 else { return source }
        let scaleX = source.size.width  / imageRect.width
        let scaleY = source.size.height / imageRect.height
        let pixRect = CGRect(
            x: (cropRect.minX - imageRect.minX) * scaleX,
            y: (cropRect.minY - imageRect.minY) * scaleY,
            width:  cropRect.width  * scaleX,
            height: cropRect.height * scaleY
        ).intersection(CGRect(origin: .zero, size: source.size))

        guard !pixRect.isEmpty, let cg = source.cgImage?.cropping(to: pixRect) else { return source }
        return UIImage(cgImage: cg, scale: source.scale, orientation: source.imageOrientation)
    }
}

// MARK: - CGRect helper

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let x = Swift.max(bounds.minX, Swift.min(minX, bounds.maxX - width))
        let y = Swift.max(bounds.minY, Swift.min(minY, bounds.maxY - height))
        let w = Swift.min(width,  bounds.width)
        let h = Swift.min(height, bounds.height)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
```

- [ ] 运行裁剪测试，确认全部通过：

```bash
xcodebuild test -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SmileTests/PhotoCropTests 2>&1 | grep -E "Test (Suite|Case|Passed|Failed)"
```

Expected: 4 tests passed.

- [ ] Commit：

```bash
git add Smile/Features/EntryEditor/PhotoCropView.swift SmileTests/PhotoCropTests.swift
git commit -m "feat: add PhotoCropView with draggable crop handles and unit-tested crop math"
```

---

## Task 2: CameraPickerView — 相机拍摄 + 直接进裁剪

**Files:**
- Create: `Smile/Features/EntryEditor/CameraPickerView.swift`

- [ ] 新建 `Smile/Features/EntryEditor/CameraPickerView.swift`：

```swift
import SwiftUI
import UIKit

// MARK: - UIImagePickerController wrapper for camera

struct CameraPickerView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let img = info[.originalImage] as? UIImage else { parent.onCancel(); return }
            parent.onCapture(img)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - CameraFlow: camera → crop → callback

struct CameraFlow: View {
    var onFinish: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var capturedImage: UIImage? = nil

    var body: some View {
        if let img = capturedImage {
            PhotoCropView(image: img) { cropped in
                onFinish(cropped)
            } onCancel: {
                capturedImage = nil
                onCancel()
            }
        } else {
            CameraPickerView { img in
                capturedImage = img
            } onCancel: {
                onCancel()
            }
        }
    }
}
```

- [ ] 编译验证（不需要设备，仅检查编译）：

```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] Commit：

```bash
git add Smile/Features/EntryEditor/CameraPickerView.swift
git commit -m "feat: add CameraPickerView and CameraFlow (camera → crop)"
```

---

## Task 3: PhotoPreviewView — 大图预览

**Files:**
- Create: `Smile/Features/EntryEditor/PhotoPreviewView.swift`

大图预览接收一组 PHAsset，在当前 asset 上展示，支持左右翻页，带勾选/确定/编辑按钮。

- [ ] 新建 `Smile/Features/EntryEditor/PhotoPreviewView.swift`：

```swift
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
                Group {
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
```

- [ ] 编译检查：

```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] Commit：

```bash
git add Smile/Features/EntryEditor/PhotoPreviewView.swift
git commit -m "feat: add PhotoPreviewView with check/edit/confirm actions"
```

---

## Task 4: PhotoLibraryPickerView — 相册网格选择器

**Files:**
- Create: `Smile/Features/EntryEditor/PhotoLibraryPickerView.swift`

- [ ] 新建 `Smile/Features/EntryEditor/PhotoLibraryPickerView.swift`：

```swift
import SwiftUI
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
            Group {
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
                Group {
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
            Text("请在"设置 → 隐私 → 照片"中允许访问")
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
        var loaded: [UIImage] = []
        let group = DispatchGroup()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isSynchronous = false
        opts.isNetworkAccessAllowed = true
        for asset in ordered {
            group.enter()
            PHImageManager.default().requestImage(
                for: asset, targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit, options: opts
            ) { img, _ in
                if let img { loaded.append(img) }
                group.leave()
            }
        }
        group.notify(queue: .main) { onSelect(loaded) }
    }
}
```

- [ ] 编译检查：

```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] Commit：

```bash
git add Smile/Features/EntryEditor/PhotoLibraryPickerView.swift
git commit -m "feat: add PhotoLibraryPickerView with WeChat-style grid and multi-select"
```

---

## Task 5: iOSNoteEditorView — 接入新选择器和拍摄入口

**Files:**
- Modify: `Smile/Features/EntryEditor/iOSNoteEditorView.swift`

改动范围：
1. 移除 `PhotosPicker` 相关 import 和 `@State private var photoPickerItems`
2. 新增 `showPhotoPicker` / `showCamera` 两个 State
3. 替换工具栏按钮
4. 新增 `insertPhoto(_ image: UIImage)` 方法
5. 连接 sheet/fullScreenCover

- [ ] 修改 import 区域（第 1-3 行），移除 PhotosUI，保留其余：

```swift
import SwiftUI
import SwiftData
```

- [ ] 移除第 28 行的 `@State private var photoPickerItems: [PhotosPickerItem] = []`，新增：

```swift
@State private var showPhotoPicker = false
@State private var showCamera = false
```

- [ ] 移除 `.onChange(of: photoPickerItems)` 这一行（当前第 72 行）

- [ ] 在现有两个 `.sheet` 之后（第 76 行附近）新增两个覆层：

```swift
.sheet(isPresented: $showPhotoPicker) {
    PhotoLibraryPickerView { images in
        showPhotoPicker = false
        Task { for img in images { await insertPhoto(img) } }
    } onCancel: {
        showPhotoPicker = false
    }
}
.fullScreenCover(isPresented: $showCamera) {
    CameraFlow { img in
        showCamera = false
        Task { await insertPhoto(img) }
    } onCancel: {
        showCamera = false
    }
}
```

- [ ] 将工具栏区域（`toolbarRow`，第 151-173 行）替换为：

```swift
@ViewBuilder
private var toolbarRow: some View {
    HStack(spacing: 18) {
        Button { showPhotoPicker = true } label: {
            Label("相册", systemImage: "photo.on.rectangle")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
        }
        Button { showCamera = true } label: {
            Label("拍摄", systemImage: "camera")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
        }
        Button { showVoiceRecorder = true } label: {
            Label("语音", systemImage: "mic")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
        }
        Button { showTagPicker = true } label: {
            Label("标签", systemImage: "number")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
        }
        Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
}
```

- [ ] 移除 `loadPickedItems` 方法（第 310-327 行），新增 `insertPhoto`：

```swift
@MainActor
private func insertPhoto(_ image: UIImage) async {
    guard let data = image.jpegData(compressionQuality: 0.9) else { return }
    let mediaStore = MediaStore.production()
    let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
    guard let relPath = try? mediaStore.save(data: data, entryID: entryDraftID, filename: filename) else { return }
    var draft = DraftAttachment(kind: .photo, relativePath: relPath)
    draft.persistedID = nil
    if let thumbData = ThumbnailGenerator.makePhotoThumbnail(from: data),
       let img = UIImage(data: thumbData) {
        thumbnails[draft.id] = img
    }
    let anchorID = focusedSegmentID
    model.insertPhoto(draft, afterSegmentID: anchorID)
    model.isDirty = true
}
```

- [ ] 编译检查：

```bash
xcodebuild build -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] 全量测试：

```bash
xcodebuild test -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "Test Suite.*passed|FAILED|error:"
```

Expected: Test Suite passed, no failures.

- [ ] Commit：

```bash
git add Smile/Features/EntryEditor/iOSNoteEditorView.swift
git commit -m "feat: replace PhotosPicker with album picker + camera in editor toolbar"
```

---

## 验收标准

- [ ] 点击"相册"弹出自定义网格，照片从 Photos 框架加载
- [ ] 点击格子右上角圆圈 → 勾选（蓝色），再次点击 → 取消
- [ ] 多张勾选后点"确定" → 全部插入编辑器，无裁剪弹窗
- [ ] 点击格子缩略图 → 进入大图预览，可左右翻页
- [ ] 大图预览：只有0张或1张选中时"编辑"按钮可用
- [ ] 点"编辑" → 进裁剪，拖动角点可调整裁剪框，双指缩放照片，完成后插入
- [ ] 点"确定" → 直接插入当前图，无裁剪
- [ ] 点击"拍摄" → 打开相机，拍完自动进裁剪，完成后插入
- [ ] 相册权限拒绝时显示引导文案
- [ ] 所有单元测试通过
