import UIKit

@MainActor
enum HapticFeedback {
    static func kept() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func queuedForDeletion() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    static func undone() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func deletionCompleted() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

