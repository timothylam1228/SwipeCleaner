# SwipeCleaner

SwipeCleaner is a native SwiftUI photo triage app for iPhone (iOS 17+). Swipe left to queue a photo for deletion or right to keep it. Nothing is deleted until you review the queue and confirm the final iOS Photos deletion prompt.

## Features

- PhotoKit read/write authorization, including limited-library handling
- Newest-first, one-card-at-a-time review with swipe and button controls
- All-photo, recent, yearly, and custom date-range review
- iCloud image downloads and nearby-photo prefetching through `PHCachingImageManager`
- A pre-rendered next-card stack and 12-photo cache window for faster swiping
- Persistent review and deletion-queue progress across launches
- Full-screen photo details with pinch and double-tap zoom
- Native haptic feedback for keep, delete, undo, warnings, and completed deletion
- On-device Vision scanning for user-reviewed similar-photo groups
- Automatic protection for favorited photos
- Undo for the last decision
- Review grid with individual removal from the deletion queue
- One batch deletion using `PHPhotoLibrary.performChanges`
- Loading, denied, limited, empty, finished, and error states
- Native Apple frameworks only; no package dependencies

## Run on an iPhone

1. Clone the repository:
   ```sh
   git clone https://github.com/timothylam1228/SwipeCleaner.git
   cd SwipeCleaner
   ```
2. Open `SwipeCleaner.xcodeproj` in Xcode 15 or newer.
3. Select the **SwipeCleaner** project, select the **SwipeCleaner** target, and open **Signing & Capabilities**.
4. Enable **Automatically manage signing** and choose your **Personal Team**. Change the bundle identifier if Xcode says it is unavailable.
5. Connect and unlock an iPhone running iOS 17 or later, trust the Mac if prompted, and select the iPhone as the run destination.
6. Press **Run** (⌘R). On first launch, grant full or limited photo-library access.

Deletion always uses Apple's confirmation sheet. If access is denied, use the app's **Open Settings** button. With limited access, **Manage Access** opens Apple's photo picker so you can add more photos.

## Build verification

On macOS with Xcode installed:

```sh
xcodebuild -project SwipeCleaner.xcodeproj \
  -scheme SwipeCleaner \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Run the state-machine tests in Xcode with **Product → Test** (⌘U), or from Terminal:

```sh
xcodebuild test -project SwipeCleaner.xcodeproj -scheme SwipeCleaner -destination 'platform=iOS Simulator,name=iPhone 15'
```

GitHub Actions also builds the app and runs the unit tests in an iPhone simulator after every push and pull request.
