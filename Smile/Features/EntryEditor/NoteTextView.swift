import SwiftUI
import UIKit

/// 编辑器的文字块。仿备忘录：承载标题的文字块里，第一行按标题样式显示，其余按正文样式；存储仍是纯文本
struct NoteTextView: UIViewRepresentable {
    let segmentID: UUID
    let text: String
    let hasTitle: Bool
    let alignment: TextAlignment
    let minHeight: CGFloat
    @Binding var focusedSegmentID: UUID?
    let onChange: (String) -> Void
    /// 用户移动光标或输入时回报光标位置（UTF-16 偏移）
    var onCursorChange: (Int) -> Void = { _ in }

    static let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
    static let bodyFont = UIFont.systemFont(ofSize: 16, weight: .regular)

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        context.coordinator.applyStyle(to: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        let styleChanged = coordinator.parent.hasTitle != hasTitle || coordinator.parent.alignment != alignment
        coordinator.parent = self

        // 外部改动（语音输入、AI 整理替换等）；输入法组字期间不动文字，以免打断
        if view.text != text, view.markedTextRange == nil {
            let selection = view.selectedRange
            // 外部改文字引起的光标变化不算用户移动光标，不回报
            coordinator.isApplyingExternalText = true
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            coordinator.applyStyle(to: view)
            coordinator.isApplyingExternalText = false
        } else if styleChanged {
            coordinator.applyStyle(to: view)
        }

        // 焦点同步放到下一轮，避免在视图更新过程中改动 SwiftUI 状态
        let shouldFocus = focusedSegmentID == segmentID
        if shouldFocus != view.isFirstResponder {
            DispatchQueue.main.async {
                guard view.window != nil, (coordinator.parent.focusedSegmentID == segmentID) == shouldFocus else { return }
                if shouldFocus { view.becomeFirstResponder() } else { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(ceil(fitted.height), minHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var isApplyingExternalText = false
        var parent: NoteTextView

        init(_ parent: NoteTextView) { self.parent = parent }

        /// 标题行的范围（不含换行符）；没有标题时为 nil
        private func titleRange(in text: NSString) -> NSRange? {
            guard parent.hasTitle else { return nil }
            let newline = text.range(of: "\n")
            return NSRange(location: 0, length: newline.location == NSNotFound ? text.length : newline.location)
        }

        private func attributes(title: Bool) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = parent.alignment == .center ? .center : .natural
            if title { paragraph.paragraphSpacing = 6 }
            return [
                .font: title ? NoteTextView.titleFont : NoteTextView.bodyFont,
                .foregroundColor: UIColor(AppColors.textPrimary),
                .paragraphStyle: paragraph,
            ]
        }

        func applyStyle(to view: UITextView) {
            let storage = view.textStorage
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(attributes(title: false), range: full)
            if let title = titleRange(in: storage.string as NSString), title.length > 0 {
                storage.setAttributes(attributes(title: true), range: title)
            }
            storage.endEditing()
            updateTypingAttributes(of: view)
        }

        /// 光标在标题行时按标题样式输入，换行后回到正文样式
        private func updateTypingAttributes(of view: UITextView) {
            let inTitle = titleRange(in: view.text as NSString).map { view.selectedRange.location <= NSMaxRange($0) } ?? false
            view.typingAttributes = attributes(title: inTitle)
        }

        func textViewDidChange(_ view: UITextView) {
            // 组字期间（如拼音未上屏）不改样式，靠 typingAttributes 决定新字样式
            if view.markedTextRange == nil { applyStyle(to: view) }
            parent.onChange(view.text)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            if view.markedTextRange == nil { updateTypingAttributes(of: view) }
            if !isApplyingExternalText, view.isFirstResponder {
                parent.onCursorChange(view.selectedRange.location)
            }
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if parent.focusedSegmentID != parent.segmentID { parent.focusedSegmentID = parent.segmentID }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.focusedSegmentID == parent.segmentID { parent.focusedSegmentID = nil }
        }
    }
}
