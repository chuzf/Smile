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
        SwiftUI.Group {
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
        // source.size is in points; cgImage dimensions are in pixels, so multiply by scale
        let s = source.scale
        let scaleX = source.size.width  / imageRect.width  * s
        let scaleY = source.size.height / imageRect.height * s
        let pixelBounds = CGRect(origin: .zero, size: CGSize(width: source.size.width * s,
                                                              height: source.size.height * s))
        let pixRect = CGRect(
            x: (cropRect.minX - imageRect.minX) * scaleX,
            y: (cropRect.minY - imageRect.minY) * scaleY,
            width:  cropRect.width  * scaleX,
            height: cropRect.height * scaleY
        ).intersection(pixelBounds)

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
