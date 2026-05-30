# Text Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-segment text alignment (leading / center) to the iOS note editor and detail view.

**Architecture:** Extend `BodySegment` with an optional `alignment: String?` field (nil = leading, "center" = center) for persistence, and `EditorSegment.text` with `alignment: TextAlignment` for in-memory state. The editor shows a floating mini-toolbar above the focused segment; the detail view reads the stored alignment when rendering.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Test` / `#expect`), Xcode 16, iOS 18 Simulator

---

## File Map

| File | Change |
|------|--------|
| `SmileJar/Features/EntryEditor/iOSNoteEditorModel.swift` | Extend `BodySegment`, `EditorSegment`; update every method that creates/matches `EditorSegment.text`; add `updateAlignment`; add `BodySegment` computed helpers |
| `SmileJar/Features/EntryEditor/iOSNoteEditorView.swift` | Wrap `TextEditor` in `VStack`, add conditional floating toolbar, add `alignButton` helper |
| `SmileJar/Features/EntryDetail/EntryDetailView.swift` | Apply `multilineTextAlignment` + `frameAlignment` in `bodyContent` |
| `SmileJarTests/iOSNoteEditorModelTests.swift` | Add alignment tests (do not remove existing tests) |

---

### Task 1: Extend `BodySegment` and `EditorSegment` types

**Files:**
- Modify: `SmileJar/Features/EntryEditor/iOSNoteEditorModel.swift:6-29`

- [ ] **Step 1: Replace `BodySegment` struct and its `Codable` extension (lines 6–15)**

```swift
struct BodySegment {
    enum Kind: String, Codable { case text, photo }
    let kind: Kind
    var content: String?
    var path: String?
    var alignment: String?  // nil = leading, "center" = center
}

extension BodySegment: Codable {
    enum CodingKeys: String, CodingKey { case kind, content, path, alignment }
}
```

- [ ] **Step 2: Replace `EditorSegment` enum (lines 19–29) to carry `alignment`**

```swift
enum EditorSegment: Identifiable {
    case text(id: UUID, content: String, alignment: TextAlignment)
    case photo(DraftAttachment)

    var id: UUID {
        switch self {
        case .text(let id, _, _): return id
        case .photo(let d): return d.id
        }
    }
}
```

- [ ] **Step 3: Add `BodySegment` computed helpers immediately after the `Codable` extension (after line 15)**

```swift
extension BodySegment {
    var textAlignment: TextAlignment {
        alignment == "center" ? .center : .leading
    }
    var frameAlignment: Alignment {
        alignment == "center" ? .center : .leading
    }
}
```

---

### Task 2: Fix all `EditorSegment.text` call sites to compile

**Files:**
- Modify: `SmileJar/Features/EntryEditor/iOSNoteEditorModel.swift`

All changes are in `iOSNoteEditorModel.swift`. After this task the project must build without errors.

- [ ] **Step 1: Default segment in `segments` property (line 34)**

Old:
```swift
var segments: [EditorSegment] = [.text(id: UUID(), content: "")]
```
New:
```swift
var segments: [EditorSegment] = [.text(id: UUID(), content: "", alignment: .leading)]
```

- [ ] **Step 2: `hasContent` computed property (line 60)**

Old:
```swift
if case .text(_, let c) = $0 { return !c.isEmpty } else { return false }
```
New:
```swift
if case .text(_, let c, _) = $0 { return !c.isEmpty } else { return false }
```

- [ ] **Step 3: `textContent(for:)` (line 69)**

Old:
```swift
if case .text(let id, let content) = seg, id == segmentID { return content }
```
New:
```swift
if case .text(let id, let content, _) = seg, id == segmentID { return content }
```

- [ ] **Step 4: `updateText(_:for:)` (lines 76–77) — preserve alignment when updating text**

Old:
```swift
if case .text(let id, _) = segments[i], id == segmentID {
    segments[i] = .text(id: id, content: content)
```
New:
```swift
if case .text(let id, _, let alignment) = segments[i], id == segmentID {
    segments[i] = .text(id: id, content: content, alignment: alignment)
```

- [ ] **Step 5: `insertPhoto(_:afterSegmentID:)` — new text segments default to `.leading` (lines 89, 93)**

Old (two occurrences):
```swift
segments.append(.text(id: UUID(), content: ""))
// ...
segments.insert(.text(id: UUID(), content: ""), at: anchorIdx + 2)
```
New:
```swift
segments.append(.text(id: UUID(), content: "", alignment: .leading))
// ...
segments.insert(.text(id: UUID(), content: "", alignment: .leading), at: anchorIdx + 2)
```

- [ ] **Step 6: `extractTitle()` (line 106)**

Old:
```swift
if case .text(_, let content) = seg {
```
New:
```swift
if case .text(_, let content, _) = seg {
```

- [ ] **Step 7: `buildBodySegments()` — update switch match (line 121) and all three `BodySegment(...)` initializers (lines 127, 130, 133)**

Old switch case:
```swift
case .text(_, let content):
```
New:
```swift
case .text(_, let content, let alignment):
```

Old `BodySegment` calls:
```swift
result.append(BodySegment(kind: .text, content: body, path: nil))
// ...
result.append(BodySegment(kind: .text, content: content, path: nil))
// ...
result.append(BodySegment(kind: .photo, content: nil, path: draft.relativePath))
```
New (encode alignment; photo segment always nil):
```swift
let alignStr: String? = alignment == .center ? "center" : nil
result.append(BodySegment(kind: .text, content: body, path: nil, alignment: alignStr))
// ...
result.append(BodySegment(kind: .text, content: content, path: nil, alignment: alignStr))
// ...
result.append(BodySegment(kind: .photo, content: nil, path: draft.relativePath, alignment: nil))
```

Note: `alignStr` must be declared once per `case .text` block, before both `.text` appends. The full updated `case .text` block:

```swift
case .text(_, let content, let alignment):
    let alignStr: String? = alignment == .center ? "center" : nil
    if !titleLineConsumed {
        titleLineConsumed = true
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let body = parts.count > 1 ? String(parts[1]) : ""
        if !body.isEmpty {
            result.append(BodySegment(kind: .text, content: body, path: nil, alignment: alignStr))
        }
    } else if !content.isEmpty {
        result.append(BodySegment(kind: .text, content: content, path: nil, alignment: alignStr))
    }
```

- [ ] **Step 8: Plain-text fallback in `load(from:)` (lines 174, 177)**

Old:
```swift
var built: [EditorSegment] = [.text(id: UUID(), content: firstText)]
// ...
built.append(.text(id: UUID(), content: ""))
```
New:
```swift
var built: [EditorSegment] = [.text(id: UUID(), content: firstText, alignment: .leading)]
// ...
built.append(.text(id: UUID(), content: "", alignment: .leading))
```

- [ ] **Step 9: `reset()` (line 226)**

Old:
```swift
segments = [.text(id: UUID(), content: "")]
```
New:
```swift
segments = [.text(id: UUID(), content: "", alignment: .leading)]
```

- [ ] **Step 10: `buildEditorSegments(title:bodySegs:allAttachments:)` (lines 245, 251, 263)**

Old first segment:
```swift
var built: [EditorSegment] = [.text(id: UUID(), content: firstEditorText)]
```
New (decode alignment from first body segment if it's text):
```swift
let firstAlignment: TextAlignment = firstBodyIsText ? (bodySegs.first?.textAlignment ?? .leading) : .leading
var built: [EditorSegment] = [.text(id: UUID(), content: firstEditorText, alignment: firstAlignment)]
```

Old text body segment:
```swift
built.append(.text(id: UUID(), content: bodySeg.content ?? ""))
```
New:
```swift
built.append(.text(id: UUID(), content: bodySeg.content ?? "", alignment: bodySeg.textAlignment))
```

Old trailing text segment after photo:
```swift
built.append(.text(id: UUID(), content: ""))
```
New:
```swift
built.append(.text(id: UUID(), content: "", alignment: .leading))
```

- [ ] **Step 11: `collapseAdjacentTextSegments()` (lines 272–274, 279)**

Old:
```swift
if case .text(_, let newContent) = seg,
   let last = result.last, case .text(let lastID, let lastContent) = last {
    result[result.count - 1] = .text(id: lastID, content: lastContent + newContent)
// ...
if result.isEmpty { result = [.text(id: UUID(), content: "")] }
```
New (merged segment keeps the first segment's alignment):
```swift
if case .text(_, let newContent, _) = seg,
   let last = result.last, case .text(let lastID, let lastContent, let lastAlignment) = last {
    result[result.count - 1] = .text(id: lastID, content: lastContent + newContent, alignment: lastAlignment)
// ...
if result.isEmpty { result = [.text(id: UUID(), content: "", alignment: .leading)] }
```

- [ ] **Step 12: Fix `BodySegment` initializer in `EntryDetailView.swift` (line 111)**

Old:
```swift
return [BodySegment(kind: .text, content: entry.bodyText, path: nil)]
```
New:
```swift
return [BodySegment(kind: .text, content: entry.bodyText, path: nil, alignment: nil)]
```

- [ ] **Step 13: Verify the project builds**

Run:
```
xcodebuild build -project SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED`

---

### Task 3: Add `updateAlignment` method and write tests

**Files:**
- Modify: `SmileJar/Features/EntryEditor/iOSNoteEditorModel.swift`
- Modify: `SmileJarTests/iOSNoteEditorModelTests.swift`

- [ ] **Step 1: Add `updateAlignment(_:for:)` to `iOSNoteEditorModel` after `updateText`**

```swift
func updateAlignment(_ alignment: TextAlignment, for segmentID: UUID) {
    for i in segments.indices {
        if case .text(let id, let content, _) = segments[i], id == segmentID {
            segments[i] = .text(id: id, content: content, alignment: alignment)
            isDirty = true
            return
        }
    }
}
```

- [ ] **Step 2: Write failing tests in `SmileJarTests/iOSNoteEditorModelTests.swift`**

Append these tests inside the `iOSNoteEditorModelTests` struct (keep the existing tests):

```swift
@Test("updateAlignment changes segment alignment to center")
func updateAlignment_changesAlignmentToCenter() {
    let model = iOSNoteEditorModel()
    guard case .text(let id, _, _) = model.segments.first else {
        Issue.record("Expected first segment to be text"); return
    }
    model.updateAlignment(.center, for: id)
    guard case .text(_, _, let alignment) = model.segments.first else {
        Issue.record("Expected first segment to be text"); return
    }
    #expect(alignment == .center)
}

@Test("updateAlignment marks model as dirty")
func updateAlignment_marksDirty() {
    let model = iOSNoteEditorModel()
    model.isDirty = false
    guard case .text(let id, _, _) = model.segments.first else {
        Issue.record("Expected first segment to be text"); return
    }
    model.updateAlignment(.center, for: id)
    #expect(model.isDirty == true)
}

@Test("buildBodySegments encodes center alignment")
func buildBodySegments_encodesCenterAlignment() {
    let model = iOSNoteEditorModel()
    guard case .text(let id, _, _) = model.segments.first else {
        Issue.record("Expected first segment to be text"); return
    }
    model.updateText("Title\nBody text", for: id)
    model.updateAlignment(.center, for: id)
    let segs = model.buildBodySegments()
    #expect(segs.count == 1)
    #expect(segs[0].content == "Body text")
    #expect(segs[0].alignment == "center")
}

@Test("buildBodySegments uses nil alignment for leading")
func buildBodySegments_nilAlignmentForLeading() {
    let model = iOSNoteEditorModel()
    guard case .text(let id, _, _) = model.segments.first else {
        Issue.record("Expected first segment to be text"); return
    }
    model.updateText("Title\nBody text", for: id)
    let segs = model.buildBodySegments()
    #expect(segs.count == 1)
    #expect(segs[0].alignment == nil)
}

@Test("encode then decode round-trips center alignment")
func bodySeg_roundTrips_centerAlignment() {
    let original = [BodySegment(kind: .text, content: "Hello", path: nil, alignment: "center")]
    let encoded = iOSNoteEditorModel.encodeBodySegments(original)
    let decoded = iOSNoteEditorModel.decodeBodySegments(from: encoded)
    #expect(decoded?.first?.alignment == "center")
}

@Test("decode old body JSON without alignment field defaults to nil")
func bodySeg_decodeOldFormat_nilAlignment() {
    let oldJSON = #"[{"kind":"text","content":"Hello"}]"#
    let decoded = iOSNoteEditorModel.decodeBodySegments(from: oldJSON)
    #expect(decoded?.first?.alignment == nil)
}
```

- [ ] **Step 3: Run tests to verify they fail with meaningful errors**

Run:
```
xcodebuild test -project SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SmileJarTests/iOSNoteEditorModelTests 2>&1 | grep -E "(Test.*passed|Test.*failed|error:)" | head -20
```
Expected: new tests fail (methods exist but alignment logic not yet tested), existing tests may also fail due to stale API in `iOSNoteEditorModelTests` — that's OK for now.

- [ ] **Step 4: Run all new tests to verify they pass (after Task 2 changes are complete)**

Run:
```
xcodebuild test -project SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SmileJarTests/iOSNoteEditorModelTests 2>&1 | grep -E "(passed|failed)" | tail -15
```
Expected: all 6 new alignment tests pass.

- [ ] **Step 5: Commit**

```bash
git add SmileJar/Features/EntryEditor/iOSNoteEditorModel.swift SmileJarTests/iOSNoteEditorModelTests.swift
git commit -m "feat: add per-segment text alignment to data model"
```

---

### Task 4: Add floating alignment toolbar to the editor

**Files:**
- Modify: `SmileJar/Features/EntryEditor/iOSNoteEditorView.swift`

- [ ] **Step 1: Add `alignButton` private helper view before the closing brace of `iOSNoteEditorView`**

Add this inside `iOSNoteEditorView` (after the `removeVoice` method, before the closing `}`):

```swift
@ViewBuilder
private func alignButton(icon: String, align: TextAlignment, current: TextAlignment, segmentID: UUID) -> some View {
    Button {
        model.updateAlignment(align, for: segmentID)
    } label: {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(current == align ? Color.white : AppColors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(current == align ? AppColors.warmOrange : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
```

- [ ] **Step 2: Replace the `.text` case in `segmentView(_:)` (lines 99–108)**

Old:
```swift
case .text(let id, _):
    TextEditor(text: textBinding(for: id))
        .scrollContentBackground(.hidden)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(AppColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: 80)
        .focused($focusedSegmentID, equals: id)
        .onChange(of: model.textContent(for: id)) { _, _ in model.scheduleAutoSave() }
```
New:
```swift
case .text(let id, _, let alignment):
    VStack(alignment: .leading, spacing: 0) {
        if focusedSegmentID == id {
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    alignButton(icon: "text.alignleft",   align: .leading, current: alignment, segmentID: id)
                    alignButton(icon: "text.aligncenter", align: .center,  current: alignment, segmentID: id)
                }
                .padding(4)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                .padding(.trailing, 16)
                .padding(.top, 4)
            }
        }
        TextEditor(text: textBinding(for: id))
            .scrollContentBackground(.hidden)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(minHeight: 80)
            .focused($focusedSegmentID, equals: id)
            .multilineTextAlignment(alignment)
            .onChange(of: model.textContent(for: id)) { _, _ in model.scheduleAutoSave() }
    }
```

- [ ] **Step 3: Build to verify no errors**

```
xcodebuild build -project SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add SmileJar/Features/EntryEditor/iOSNoteEditorView.swift
git commit -m "feat: add floating alignment toolbar to note editor"
```

---

### Task 5: Apply alignment in EntryDetailView

**Files:**
- Modify: `SmileJar/Features/EntryDetail/EntryDetailView.swift`

- [ ] **Step 1: Update the `.text` case inside `bodyContent` (lines 83–88)**

Old:
```swift
case .text:
    if let text = seg.content, !text.isEmpty {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(AppColors.textPrimary.opacity(0.9))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
```
New:
```swift
case .text:
    if let text = seg.content, !text.isEmpty {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(AppColors.textPrimary.opacity(0.9))
            .lineSpacing(4)
            .multilineTextAlignment(seg.textAlignment)
            .frame(maxWidth: .infinity, alignment: seg.frameAlignment)
    }
```

- [ ] **Step 2: Build to verify no errors**

```
xcodebuild build -project SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run full test suite**

```
xcodebuild test -project SmileJar.xcodeproj -scheme SmileJar -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(Test Suite|passed|failed)" | tail -10
```
Expected: all tests pass (6 new alignment tests + existing tests).

- [ ] **Step 4: Commit**

```bash
git add SmileJar/Features/EntryDetail/EntryDetailView.swift
git commit -m "feat: render per-segment text alignment in entry detail view"
```
