import SwiftUI
import SwiftData

struct TagFilterBar: View {
    let allTags: [Tag]
    @Binding var selectedTagIDs: Set<PersistentIdentifier>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allTags) { tag in
                    let isSel = selectedTagIDs.contains(tag.persistentModelID)
                    TagChip(name: tag.name,
                            color: Color(hex: tag.colorHex),
                            selected: isSel)
                        .onTapGesture {
                            if isSel { selectedTagIDs.remove(tag.persistentModelID) }
                            else { selectedTagIDs.insert(tag.persistentModelID) }
                        }
                }
            }
            .padding(.horizontal, 14)
        }
    }
}
