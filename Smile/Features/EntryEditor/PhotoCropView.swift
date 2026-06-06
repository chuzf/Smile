import SwiftUI
import UIKit

struct PhotoCropView: View {
    let image: UIImage
    var onCrop: (UIImage) -> Void
    var onCancel: () -> Void

    // Image pan/zoom
    @State private var imgScale: CGFloat = 1
    @State private var lastImgScale: CGFloat = 1
    @State private var imgOffset: CGSize = .zero
    @State private var lastImgOffset: CGSize = .zero
    @State private var isPinching = false
    @State private var firstPinchValue: CGFloat? = nil

    // Crop frame (view coords)
    @State private var cropRect: CGRect = .zero
    @State private var containerSize: CGSize = .zero
    @State private var cropInitialized = false
    private let minCrop: CGFloat = 60
    private let handleHit: CGFloat = 32

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // 顶部操作栏
                HStack {
                    Button("取消", action: onCancel)
                        .foregroundStyle(.white)
                        .padding()
                    Spacer()
                }
                .frame(height: 56)

                // 图片编辑区域（不延伸到顶部/底部操作栏）
                GeometryReader { geo in
                    ZStack {
                        imageLayer(geo: geo)
                        dimmingLayer(geo: geo)
                        cropBorder
                        cornerHandles(geo: geo)
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(imageDrag)
                    .simultaneousGesture(imagePinch)
                    .onAppear { initCrop(geo.size) }
                }

                // 底部操作栏
                HStack {
                    Spacer()
                    Button("完成") { commit() }
                        .foregroundStyle(.white)
                        .padding()
                }
                .frame(height: 56)
            }
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
        SwiftUI.Group {
            CropCornerHandle(point: CGPoint(x: cropRect.minX, y: cropRect.minY), handleHit: handleHit) { d in
                stretchCorner(.topLeft, delta: d, geo: geo)
            }
            CropCornerHandle(point: CGPoint(x: cropRect.maxX, y: cropRect.minY), handleHit: handleHit) { d in
                stretchCorner(.topRight, delta: d, geo: geo)
            }
            CropCornerHandle(point: CGPoint(x: cropRect.minX, y: cropRect.maxY), handleHit: handleHit) { d in
                stretchCorner(.bottomLeft, delta: d, geo: geo)
            }
            CropCornerHandle(point: CGPoint(x: cropRect.maxX, y: cropRect.maxY), handleHit: handleHit) { d in
                stretchCorner(.bottomRight, delta: d, geo: geo)
            }
        }
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

    // MARK: - Constraint helpers

    // 图片在 scale=1 时的基础尺寸（scaledToFit 结果）
    private func baseImageSize(in size: CGSize) -> CGSize {
        let aspect = image.size.width / image.size.height
        let containerAspect = size.width / size.height
        if aspect > containerAspect {
            return CGSize(width: size.width, height: size.width / aspect)
        } else {
            return CGSize(width: size.height * aspect, height: size.height)
        }
    }

    // 保证图片铺满裁剪框所需的最小缩放值
    private func minimumScale(for size: CGSize) -> CGFloat {
        guard cropRect.width > 0, cropRect.height > 0 else { return 1 }
        let base = baseImageSize(in: size)
        return max(cropRect.width / base.width, cropRect.height / base.height)
    }

    // 最大缩放 = 最小缩放的 4 倍，保证裁剪区域至少占原图 1/16 面积，避免像素化
    private func maximumScale(for size: CGSize) -> CGFloat {
        return minimumScale(for: size) * 4
    }

    // 将 offset 约束在合法范围内（裁剪框四边不超出图片边界）
    // 图片中心 = 容器中心 + offset，故：
    //   imageMinX = (containerW - scaledW) / 2 + offsetX
    //   需满足：imageMinX <= cropMinX 且 imageMaxX >= cropMaxX
    private func clampedOffset(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let base = baseImageSize(in: size)
        let sw = base.width * scale
        let sh = base.height * scale
        let maxX = cropRect.minX - (size.width  - sw) / 2
        let minX = cropRect.maxX - (size.width  + sw) / 2
        let maxY = cropRect.minY - (size.height - sh) / 2
        let minY = cropRect.maxY - (size.height + sh) / 2
        return CGSize(
            width:  min(maxX, max(minX, offset.width)),
            height: min(maxY, max(minY, offset.height))
        )
    }

    // MARK: - Image gestures

    private var imageDrag: some Gesture {
        DragGesture()
            .onChanged { v in
                guard !isPinching else { return }
                let proposed = CGSize(
                    width:  lastImgOffset.width  + v.translation.width,
                    height: lastImgOffset.height + v.translation.height
                )
                imgOffset = clampedOffset(proposed, scale: imgScale, in: containerSize)
            }
            .onEnded { _ in
                guard !isPinching else { return }
                lastImgOffset = imgOffset
            }
    }

    private var imagePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                isPinching = true
                // 归一化首次值，消除手势识别阈值带来的初始跳变
                let base = firstPinchValue ?? v
                if firstPinchValue == nil { firstPinchValue = v }
                let normalizedV = v / base
                let minScale = minimumScale(for: containerSize)
                let maxScale = maximumScale(for: containerSize)
                imgScale = min(maxScale, max(minScale, lastImgScale * normalizedV))
                // 缩放时同步重新约束偏移，防止缩小后裁剪框露出空白
                imgOffset = clampedOffset(lastImgOffset, scale: imgScale, in: containerSize)
            }
            .onEnded { _ in
                lastImgScale = imgScale
                lastImgOffset = imgOffset
                firstPinchValue = nil
                isPinching = false
            }
    }

    // MARK: - Init & commit

    private func initCrop(_ size: CGSize) {
        // 始终更新 containerSize，确保手势坐标计算准确
        containerSize = size
        // 仅在首次出现时初始化裁剪状态，避免前后台切换重置用户进度
        guard !cropInitialized else { return }
        cropInitialized = true
        let side = min(size.width, size.height) * 0.82
        cropRect = CGRect(x: (size.width - side) / 2,
                          y: (size.height - side) / 2,
                          width: side, height: side)
        // 初始缩放保证图片恰好铺满裁剪框，居中对齐
        let minScale = minimumScale(for: size)
        imgScale = minScale
        lastImgScale = minScale
        imgOffset = .zero
        lastImgOffset = .zero
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
        let imageCrop = CGRect(
            x: (cropRect.minX - imageRect.minX) * scaleX,
            y: (cropRect.minY - imageRect.minY) * scaleY,
            width:  cropRect.width  * scaleX,
            height: cropRect.height * scaleY
        ).intersection(CGRect(origin: .zero, size: source.size))

        guard !imageCrop.isEmpty else { return source }

        let format = UIGraphicsImageRendererFormat()
        format.scale = source.scale
        let renderer = UIGraphicsImageRenderer(size: imageCrop.size, format: format)
        return renderer.image { _ in
            source.draw(at: CGPoint(x: -imageCrop.minX, y: -imageCrop.minY))
        }
    }
}

// MARK: - Corner handle (isolated prevDelta per instance to fix two-finger simultaneous drag)

private struct CropCornerHandle: View {
    let point: CGPoint
    let handleHit: CGFloat
    let onDrag: (CGSize) -> Void
    @State private var prevDelta: CGSize = .zero

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle().size(CGSize(width: handleHit, height: handleHit)))
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let inc = CGSize(
                            width: v.translation.width - prevDelta.width,
                            height: v.translation.height - prevDelta.height
                        )
                        prevDelta = v.translation
                        onDrag(inc)
                    }
                    .onEnded { _ in prevDelta = .zero }
            )
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
