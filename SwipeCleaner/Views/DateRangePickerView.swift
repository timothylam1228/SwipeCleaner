import SwiftUI

struct DateRangePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PhotoDateFilter
    let onApply: (PhotoDateFilter) -> Void

    init(filter: PhotoDateFilter, onApply: @escaping (PhotoDateFilter) -> Void) {
        _draft = State(initialValue: filter)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photos to review") {
                    Picker("Time Range", selection: $draft.preset) {
                        ForEach(PhotoDatePreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                }

                if draft.preset == .custom {
                    Section("Custom dates") {
                        DatePicker("From", selection: $draft.startDate, in: ...draft.endDate, displayedComponents: .date)
                        DatePicker("Through", selection: $draft.endDate, in: draft.startDate...Date.now, displayedComponents: .date)
                    }
                }

                Section {
                    Text("Changing the range keeps your existing deletion queue. Within a range, photos are shown newest first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Choose Time Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}
