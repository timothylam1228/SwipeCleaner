import Photos

enum SwipeDecision {
    case delete
    case keep
}

struct SwipeHistoryEntry {
    let asset: PHAsset
    let index: Int
    let decision: SwipeDecision
}

