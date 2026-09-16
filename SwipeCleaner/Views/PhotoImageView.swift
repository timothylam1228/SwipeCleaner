import Photos
import SwiftUI

struct PhotoImageView: View {
    let asset: PHAsset
    let manager: PHImageManager
    let contentMode: ContentMode
    let requestedTargetSize: CGSize?
    @StateObject private var loader: PhotoImageLoader

    init(asset: PHAsset, manager: PHImageManager, contentMode: ContentMode = .fit, targetSize: CGSize? = nil) {
        self.asset = asset
        self.manager = manager
        self.contentMode = contentMode
        requestedTargetSize = targetSize
        _loader = StateObject(wrappedValue: PhotoImageLoader(manager: manager))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if let message = loader.errorMessage {
                    ContentUnavailableView("Photo Unavailable", systemImage: "icloud.slash", description: Text(message))
                } else {
                    ProgressView()
                }
            }
            .task(id: asset.localIdentifier) {
                let scale = UIScreen.main.scale
                let measuredSize = CGSize(width: proxy.size.width * scale, height: proxy.size.height * scale)
                loader.load(asset: asset, targetSize: requestedTargetSize ?? measuredSize, contentMode: contentMode == .fill ? .aspectFill : .aspectFit)
            }
            .onDisappear { loader.cancel() }
        }
    }
}
