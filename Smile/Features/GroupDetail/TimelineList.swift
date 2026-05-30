import SwiftUI

struct TimelineList: View {
    let entries: [Entry]   // 已按 createdAt 倒序
    let onTap: (Entry) -> Void
    var highlightedEntryID: UUID? = nil

    var body: some View {
        let groupedByMonth = Self.groupByMonth(entries)
        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
            ForEach(groupedByMonth, id: \.0) { monthLabel, items in
                Section {
                    ForEach(items) { entry in
                        EntryListRow(
                            entry: entry,
                            isHighlighted: entry.id == highlightedEntryID,
                            onTap: { onTap(entry) }
                        )
                        .padding(.horizontal, 14)
                    }
                } header: {
                    Text(monthLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.cream.opacity(0.95))
                }
            }
        }
    }

    private static func groupByMonth(_ entries: [Entry]) -> [(String, [Entry])] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        var dict: [String: [Entry]] = [:]
        var order: [String] = []
        for e in entries {
            let key = formatter.string(from: e.createdAt)
            if dict[key] == nil { order.append(key); dict[key] = [] }
            dict[key]?.append(e)
        }
        return order.map { ($0, dict[$0] ?? []) }
    }
}

struct EntryListRow: View {
    let entry: Entry
    var isHighlighted: Bool = false
    let onTap: () -> Void

    @State private var bounceScale: CGFloat = 1.0
    @State private var hasBounced = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dayLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textSecondary)
                Text(entry.title.isEmpty ? "(无标题)" : entry.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                if !mediaSummary.isEmpty {
                    Text(mediaSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppColors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .scaleEffect(bounceScale)
        .onAppear { if isHighlighted && !hasBounced { triggerBounce() } }
        .onChange(of: isHighlighted) { _, highlighted in if highlighted && !hasBounced { triggerBounce() } }
    }

    private func triggerBounce() {
        hasBounced = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.25)) { bounceScale = 1.18 }
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { bounceScale = 1.0 }
        }
    }

    private var dayLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: entry.createdAt)
    }

    private var mediaSummary: String {
        var parts: [String] = []
        let photos = entry.attachments.filter { $0.kind == .photo }.count
        let voices = entry.attachments.filter { $0.kind == .voice }.count
        if photos > 0 { parts.append("📷 \(photos)") }
        if voices > 0 { parts.append("🎙 \(voices)") }
        return parts.joined(separator: "  ")
    }
}
