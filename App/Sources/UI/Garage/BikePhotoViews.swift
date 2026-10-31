// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GarageActivity.kt:243-274 (app-features §4.4): bike photos are
// downscaled with power-of-two subsampling until the longest side is ≤ 1440 px and saved as JPEG
// quality 85 (no EXIF / GPS metadata is kept). Thumbnails are decoded off the main thread with
// ImageIO; no photo → the ride glyph tinted brand orange.

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum BikePhotoProcessing {
    /// Android `sampleSizeFor(w, h, 720)`: halve until the longest side is ≤ 2 × 720.
    static func subsample(width: Int, height: Int, target: Int = 720) -> Int {
        var sample = 1
        var longest = max(width, height)
        while longest > target * 2 {
            sample *= 2
            longest /= 2
        }
        return sample
    }

    /// Picked image data (JPEG / HEIC / PNG …) → JPEG data ready for `GarageModel.setPhoto`.
    static func jpegData(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        let sample = subsample(width: width, height: height)
        let maxPixel = max(1, max(width, height) / sample)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A downscaled, upright copy of the photo file for display.
    static func thumbnail(at url: URL, maxPixel: Int) -> BikePhotoImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return BikePhotoImage(image: image)
    }
}

/// An immutable decoded image (safe to hand from the decoding task to the main actor).
struct BikePhotoImage: @unchecked Sendable {
    let image: CGImage
}

/// The bike photo (or the ride glyph placeholder), filling the frame the caller gives it.
struct BikePhotoView: View {
    let url: URL?
    /// Longest side to decode, in pixels.
    var maxPixel: Int = 180

    @State private var photo: BikePhotoImage?

    var body: some View {
        ZStack {
            Theme.surfaceHigh
            if let photo {
                Image(decorative: photo.image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                MainRideGlyph()
                    .foregroundStyle(Theme.brand)
                    .padding(10)
                    .frame(maxWidth: 120, maxHeight: 120)
            }
        }
        .clipped()
        .task(id: reloadKey) { @MainActor in
            guard let url else {
                photo = nil
                return
            }
            let size = maxPixel
            let loaded = await Task.detached(priority: .utility) {
                BikePhotoProcessing.thumbnail(at: url, maxPixel: size)
            }.value
            guard !Task.isCancelled else { return }
            photo = loaded
        }
        .accessibilityHidden(true)
    }

    /// Changes when the file is replaced (same name, new modification date).
    private var reloadKey: String {
        guard let url else { return "none" }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(maxPixel)"
    }
}
