# 详情页照片点击放大 设计文档

**日期**：2026-10-18
**背景**：记录详情页点击照片没有反应。照片按原分辨率保存（JPEG 0.9），放大查看能看到更多细节。另外，详情页现在在 `body` 里同步读取并解码整张原图，照片多时滚动卡顿、内存占用高，需要一并修复。

---

## 决策摘要

| 项 | 决定 |
|----|------|
| 入口 | 只在记录详情页（`EntryDetailView`）；编辑器不加 |
| 查看器 | 全屏黑底；双指缩放（最大 4 倍）；双击放大到 2.5 倍，再双击还原；未放大时左右滑动切换、向下拖动关闭；单击切换顶栏 |
| 实现 | `UIPageViewController` 翻页 + 每页一个可缩放的 `UIScrollView`，包装成 SwiftUI |
| 查看器图片 | 打开时加载原图，长边上限 4096（iPhone 原片不会被缩小）；只解码当前页和相邻页 |
| 详情页图片 | 后台用 ImageIO 解码到长边 1600，内存缓存；不再在 `body` 里同步解码原图 |
| 不做 | 保存到相册、分享、编辑器内放大 |

---

## 改动范围

| 文件 | 类型 | 说明 |
|------|------|------|
| `Smile/Core/MediaStore/ImageLoader.swift` | 新增 | ImageIO 缩小解码（按 EXIF 摆正）、带缓存版本、读取摆正后的像素尺寸 |
| `Smile/Features/EntryDetail/PhotoViewer.swift` | 新增 | 全屏查看器（SwiftUI 外壳 + UIKit 翻页与缩放） |
| `Smile/Features/EntryDetail/EntryDetailView.swift` | 修改 | 正文照片改为异步加载的 `DetailPhotoView`，点击打开查看器 |
| `SmileTests/ImageLoaderTests.swift` | 新增 | ImageLoader 单测 |

---

## 一、ImageLoader

```swift
enum ImageLoader {
    static func downsampled(url: URL, maxPixel: Int) -> UIImage?
    static func cachedDownsampled(url: URL, maxPixel: Int) -> UIImage?
    static func orientedPixelSize(url: URL) -> CGSize?
}
```

- `downsampled`：`CGImageSourceCreateThumbnailAtIndex`，带 `CreateThumbnailFromImageAlways`、`CreateThumbnailWithTransform`（按 EXIF 摆正）、`ShouldCacheImmediately`、`ThumbnailMaxPixelSize`。不放大，原图比上限小时保持原尺寸。文件不存在或无法解码时返回 nil。
- `cachedDownsampled`：在 `downsampled` 外加一层 `NSCache`，key 为 `路径#maxPixel`，按位图字节数计算 cost，总上限 100MB。照片文件名带 UUID、写入后不会被改写，所以按路径缓存是安全的。
- `orientedPixelSize`：只读文件头里的像素宽高和 EXIF 方向（5–8 时交换宽高），给占位图算宽高比，避免图片加载完成时布局跳动。
- 查看器用 `downsampled(maxPixel: 4096)`，不进缓存（大图只在查看期间存在）；详情页用 `cachedDownsampled(maxPixel: 1600)`。

## 二、查看器 `PhotoViewer`

- **呈现**：详情页用 `.fullScreenCover(item:)` 打开，配合 `.presentationBackground(.clear)`，这样下拉时能透出下面的详情页。
- **SwiftUI 外壳**：
  - 背景黑色，透明度随下拉距离降低（`1 - min(offset / 400, 0.6)`）
  - 顶栏：左边关闭按钮（`xmark`），中间「当前 / 总数」；单击照片切换显示，下拉过程中隐藏
  - 状态栏隐藏
- **`ZoomablePhotoPager`**（`UIViewControllerRepresentable`）：
  - `UIPageViewController`，`.scroll` 样式，页间距 20
  - 只在翻页动画完成后回写 `currentIndex`
- **`ZoomPhotoPageVC`**：
  - `UIScrollView` 包一个 `UIImageView`。图片按 aspect fit 算出尺寸放进 scroll view，用 `contentInset` 居中，放大后不能拖到黑边以外
  - 缩放范围 1～4 倍
  - 双击：已放大则还原；否则以点击位置为中心放大到 2.5 倍
  - 单击：等双击失败后才触发，切换顶栏
  - 下拉关闭：额外一个 pan 手势，只在未放大且竖直向下为主时开始，把位移和速度回调给外壳。松手时位移超过 120pt 或速度超过 800pt/s 就关闭，否则弹回
  - 离开屏幕（`viewDidDisappear`）时还原缩放
  - 后台解码，解码期间显示菊花；解码失败显示「图片无法加载」
- **内存**：`UIPageViewController` 只保留当前页和相邻页，离开的页面被释放，位图随之释放。

## 三、详情页

- 正文的 `.photo` 段改为 `DetailPhotoView(url:onTap:)`：
  - 文件不存在时不显示，和现在一致
  - 先用 `orientedPixelSize` 算宽高比，显示同比例的占位块；`.task` 里在后台调 `cachedDownsampled(1600)`，完成后显示图片
  - 圆角 8，点击打开查看器
- 查看器的照片列表：正文里所有文件存在的照片，按正文顺序排列；初始定位到点击的那张。

## 四、测试

`ImageLoaderTests`（Swift Testing）。测试图片用 `CGImageDestination` 写进临时目录：
- 3000×2000 的图，maxPixel 1000 → 1000×667（容差 1 像素）
- maxPixel 10000 → 保持 3000×2000，不放大
- EXIF 方向为 6（需顺时针旋转 90°）→ 结果为 2000×3000，`orientedPixelSize` 也是 2000×3000
- 文件不存在 → `downsampled` 和 `orientedPixelSize` 都返回 nil
- `cachedDownsampled` 连续两次返回同一个对象

缩放、翻页、下拉关闭在模拟器里手动验证。
