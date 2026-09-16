import Foundation

struct SimilarPhotoGroup: Identifiable, Equatable {
    let assetIDs: [String]
    var id: String { assetIDs.first ?? UUID().uuidString }
}

