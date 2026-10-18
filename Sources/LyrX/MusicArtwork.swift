import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 在轮询队列中把 Music 原始封面缩为小图，避免大图反复解码或阻塞界面。
enum MusicArtwork {
    static let scriptSource = #"""
    if application "Music" is not running then return {}
    with timeout of 3 seconds
        tell application "Music"
            try
                set t to current track
                set nm to (name of t) as text
                set ar to (artist of t) as text
                set al to (album of t) as text
                set coverData to missing value
                set lyricText to ""
                try
                    if (count of artworks of t) > 0 then set coverData to raw data of artwork 1 of t
                end try
                try
                    set lyricText to (lyrics of t) as text
                end try
                return {nm, ar, al, coverData, lyricText}
            on error
                return {}
            end try
        end tell
    end timeout
    """#

    static func thumbnailData(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
