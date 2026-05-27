import SwiftUI

/// 玻璃罐 View,根据 fillRatio (0...1) 显示填充程度
/// 含轻微的"液面荡漾"动画
struct JarView: View {
    let fillRatio: Double      // 0...1
    let mainColor: Color
    let symbolName: String     // SF Symbol,如 "face.smiling"

    @State private var wave: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let neckH: CGFloat = h * 0.08
            let jarRect = CGRect(x: 0, y: neckH, width: w, height: h - neckH)
            let fillHeight = jarRect.height * CGFloat(max(0, min(1, fillRatio)))

            ZStack {
                // 罐口
                RoundedRectangle(cornerRadius: 6)
                    .fill(mainColor)
                    .frame(width: w * 0.6, height: neckH)
                    .position(x: w / 2, y: neckH / 2)

                // 罐身轮廓
                RoundedRectangle(cornerRadius: jarRect.height * 0.12)
                    .stroke(mainColor, lineWidth: 3)
                    .frame(width: jarRect.width, height: jarRect.height)
                    .position(x: jarRect.midX, y: jarRect.midY)

                // 填充
                if fillRatio > 0 {
                    LiquidShape(amplitude: 4, phase: wave)
                        .fill(
                            LinearGradient(
                                colors: [mainColor.opacity(0.55), mainColor.opacity(0.35)],
                                startPoint: .bottom, endPoint: .top
                            )
                        )
                        .frame(width: jarRect.width - 6, height: fillHeight)
                        .clipShape(RoundedRectangle(cornerRadius: jarRect.height * 0.10))
                        .position(x: jarRect.midX, y: jarRect.maxY - fillHeight / 2)
                }

                // SF Symbol 居中
                Image(systemName: symbolName)
                    .font(.system(size: w * 0.32, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                    .position(x: w / 2, y: jarRect.midY)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                wave = .pi * 2
            }
        }
    }
}

/// 用正弦波画出"液面"形状
private struct LiquidShape: Shape {
    var amplitude: CGFloat
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 2
        p.move(to: CGPoint(x: 0, y: rect.height))
        for x in stride(from: 0, through: rect.width, by: step) {
            let normalized = (x / rect.width) * .pi * 2
            let y = sin(normalized + phase) * amplitude
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}

#Preview {
    HStack(spacing: 20) {
        JarView(fillRatio: 0.0, mainColor: AppColors.warmOrange, symbolName: "face.smiling")
            .frame(width: 100, height: 130)
        JarView(fillRatio: 0.5, mainColor: AppColors.warmOrange, symbolName: "face.smiling")
            .frame(width: 100, height: 130)
        JarView(fillRatio: 0.9, mainColor: AppColors.leafGreen, symbolName: "sparkles")
            .frame(width: 100, height: 130)
    }
    .padding()
    .background(AppColors.backgroundGradient)
}
