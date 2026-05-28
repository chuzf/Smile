import SwiftUI
import SwiftData

/// Observable model for the iOS note editor
@Observable final class iOSNoteEditorModel {
    /// Unified editor text (title + body, separated by first newline)
    var editorText: String = ""

    /// Currently selected group ID
    var selectedGroupID: PersistentIdentifier?

    /// Set of selected tag IDs
    var selectedTags: Set<PersistentIdentifier> = []

    /// Draft attachments
    var attachments: [DraftAttachment] = []

    /// When this note was created
    var createdAt: Date = Date()

    /// When this note was last updated
    var updatedAt: Date = Date()

    /// Whether the note has unsaved changes
    var isDirty: Bool = false

    /// Whether an auto-save is currently in progress
    var isSaving: Bool = false

    /// Timestamp of last auto-save
    var lastAutoSaveTime: Date = Date.distantPast

    /// Private task for scheduling auto-save (managed internally)
    private var autoSaveTask: Task<Void, Never>?

    /// Initialize a new editor model
    public init() {}

    /// Extract title and body from editor text
    /// - Returns: Tuple of (title, body) split on first newline
    func extractTitleAndBody() -> (title: String, body: String) {
        let lines = editorText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = String(lines.first ?? "")
        let body = lines.count > 1 ? String(lines[1]) : ""
        return (title, body)
    }

    /// Schedule an auto-save operation
    /// - Sets isDirty to true
    /// - Cancels any previous auto-save task
    /// - Schedules new save with 3-second debounce
    func scheduleAutoSave() {
        isDirty = true

        // Cancel the existing auto-save task if it exists
        autoSaveTask?.cancel()

        // Schedule new auto-save with 3-second debounce
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            // Check if task was cancelled during sleep
            if !Task.isCancelled {
                await performAutoSave()
            }
        }
    }

    /// Perform the actual auto-save operation
    @MainActor
    func performAutoSave() async {
        isSaving = true
        defer { isSaving = false }

        // Update auto-save timestamp
        lastAutoSaveTime = Date()
        isDirty = false
        updatedAt = Date()

        // Note: The actual saving to SwiftData is handled by the View
        // This method manages the state flags and timing
    }

    /// Load state from an existing Entry for editing
    /// - Parameter entry: The Entry to load
    func load(from entry: Entry) {
        // Combine title and body with newline separator
        editorText = entry.title + "\n" + entry.bodyText
        selectedGroupID = entry.group?.persistentModelID
        selectedTags = Set(entry.tags.map { $0.persistentModelID })

        // Load attachments
        attachments = entry.attachments.map { attachment in
            DraftAttachment(
                persistedID: attachment.persistentModelID,
                kind: attachment.kind,
                relativePath: attachment.relativePath,
                transcript: attachment.transcript,
                durationSeconds: attachment.durationSeconds
            )
        }

        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        isDirty = false
        isSaving = false
        lastAutoSaveTime = Date.distantPast
    }

    /// Select a default group from available groups
    /// - Parameters:
    ///   - groups: Available groups to choose from
    ///   - initialGroupID: Optional preferred group ID
    func selectDefaultGroup(from groups: [Group], initialGroupID: PersistentIdentifier?) {
        // If an initial group ID is provided and exists in the list, use it
        if let initialGroupID = initialGroupID,
           groups.contains(where: { $0.persistentModelID == initialGroupID }) {
            selectedGroupID = initialGroupID
            return
        }

        // Otherwise, select the first available group
        selectedGroupID = groups.first?.persistentModelID
    }

    /// Reset all state to defaults
    func reset() {
        // Cancel any pending auto-save task
        autoSaveTask?.cancel()
        autoSaveTask = nil

        // Reset all state
        editorText = ""
        selectedGroupID = nil
        selectedTags = []
        attachments = []
        createdAt = Date()
        updatedAt = Date()
        isDirty = false
        isSaving = false
        lastAutoSaveTime = Date.distantPast
    }
}
