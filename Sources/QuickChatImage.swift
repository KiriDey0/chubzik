import Foundation
import ImageIO
import UniformTypeIdentifiers

enum QuickChatImage {
    static func supports(_ url: URL) -> Bool {
        url.isFileURL && !url.hasDirectoryPath
            && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func read(_ url: URL) -> Data? {
        guard !Task.isCancelled, supports(url) else { return nil }
        let file = url.resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let length = values.fileSize,
              (1...80 * 1024 * 1024).contains(length),
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source)
    }

    static func read(_ data: Data) -> Data? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData,
              [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source)
    }

    private static func thumbnail(_ source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 3000
              ] as CFDictionary) else { return nil }
        return jpeg(image)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.89] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }
}
