import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 在轮询队列中把 Music 原始封面缩为小图，避免大图反复解码或阻塞界面。
enum MusicArtwork {
    static let scriptSource = #"""
    if application "Music" is not running then return {}
    with timeout of 1 second
        tell application "Music"
            try
                set t to current track
                set nm to (name of t) as text
                set ar to (artist of t) as text
                set al to (album of t) as text
                set beforeToken to ""
                try
                    set beforeToken to persistent ID of t as text
                end try
                if beforeToken is "" or beforeToken is "missing value" or beforeToken is "0" or beforeToken is "0000000000000000" then set beforeToken to nm & "|" & ar & "|" & al
                set coverData to missing value
                try
                    if (count of artworks of t) > 0 then set coverData to raw data of artwork 1 of t
                end try
                set afterToken to ""
                try
                    set afterToken to persistent ID of current track as text
                end try
                if afterToken is "" or afterToken is "missing value" or afterToken is "0" or afterToken is "0000000000000000" then
                    set ct to current track
                    set afterToken to (name of ct as text) & "|" & (artist of ct as text) & "|" & (album of ct as text)
                end if
                return {nm, ar, al, coverData, beforeToken, afterToken}
            on error
                return {}
            end try
        end tell
    end timeout
    """#

    static func isCurrentResponse(_ response: NSAppleEventDescriptor, trackID: String, token: String) -> Bool {
        func text(_ index: Int) -> String {
            guard let value = response.atIndex(index), value.descriptorType != typeNull else { return "" }
            return value.stringValue ?? ""
        }
        return !token.isEmpty && (1...3).map(text).joined(separator: "|") == trackID &&
            text(5) == token && text(6) == token
    }

    /// 分三次读取确认 Music 的延迟封面；每首歌有固定上限，不持续轮询大图。
    static func refreshDelay(afterAttempt attempt: Int, receivedImage: Bool) -> TimeInterval? {
        guard attempt < 3 else { return nil }
        if receivedImage { return attempt == 1 ? 2.5 : 5 }
        return attempt == 1 ? 1.5 : 3
    }

    static let embeddedLyricsScriptSource = #"""
    if application "Music" is not running then return {}
    with timeout of 1 second
        tell application "Music"
            try
                set t to current track
                return {name of t as text, artist of t as text, album of t as text, lyrics of t as text}
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
