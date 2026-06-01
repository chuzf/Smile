import SwiftUI

struct TimeFilterSheet: View {
    @Binding var from: Date?
    @Binding var to: Date?
    @Environment(\.dismiss) var dismiss

    @State private var enableRange = false
    @State private var localFrom: Date = .now.addingTimeInterval(-30 * 86400)
    @State private var localTo: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                Toggle("启用时间区间筛选", isOn: $enableRange)
                if enableRange {
                    DatePicker("开始", selection: $localFrom, displayedComponents: .date)
                    DatePicker("结束", selection: $localTo, displayedComponents: .date)
                }
            }
            .navigationTitle("时间筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if enableRange {
                            // Swap if user set start > end
                            let start = min(localFrom, localTo)
                            let end   = max(localFrom, localTo)
                            from = Calendar.current.startOfDay(for: start)
                            // Set end to 23:59:59 so today's records are included
                            to = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
                        } else {
                            from = nil
                            to = nil
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                enableRange = (from != nil || to != nil)
                if let f = from { localFrom = f }
                if let t = to { localTo = t }
            }
        }
    }
}
