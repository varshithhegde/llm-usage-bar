import Foundation
import ImageIO
import CoreGraphics
import AppKit

/// Decoded sprite frames, ready to drive a Core Animation `contents` keyframe animation.
final class SpriteAnimation: @unchecked Sendable {
    let frames: [CGImage]
    let delays: [Double]
    let pixelSize: CGSize
    let sourceURL: URL?

    init?(data: Data, sourceURL: URL? = nil) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<min(count, 400) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(img)
            delays.append(Self.delay(src, i))
        }
        guard let first = frames.first else { return nil }
        self.frames = frames
        self.delays = delays
        self.pixelSize = CGSize(width: first.width, height: first.height)
        self.sourceURL = sourceURL
    }

    var isAnimated: Bool { frames.count > 1 }
    var duration: Double { delays.reduce(0, +) }

    /// Normalized cumulative key times for a discrete keyframe animation (count == frames + 1).
    var keyTimes: [Double] {
        let total = max(duration, 0.001)
        var acc = 0.0
        var out: [Double] = [0]
        for d in delays { acc += d; out.append(min(acc / total, 1)) }
        out[out.count - 1] = 1
        return out
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double)
            ?? 0.1
        // Match browser behaviour: tiny/zero delays are treated as 100 ms.
        return raw < 0.02 ? 0.1 : raw
    }
}

enum SpriteSource {
    static let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"
    static let blackWhiteMaxID = 649

    /// Ordered list of URLs to try for a given Pokémon. Shiny requests fall back to regular art.
    static func candidates(id: Int, shiny: Bool) -> [URL] {
        var s: [String] = []
        if shiny {
            if id <= blackWhiteMaxID { s.append("\(base)/versions/generation-v/black-white/animated/shiny/\(id).gif") }
            s.append("\(base)/other/showdown/shiny/\(id).gif")
            s.append("\(base)/shiny/\(id).png")
        }
        if id <= blackWhiteMaxID { s.append("\(base)/versions/generation-v/black-white/animated/\(id).gif") }
        s.append("\(base)/other/showdown/\(id).gif")
        s.append("\(base)/\(id).png")
        return s.compactMap(URL.init(string:))
    }

    static func thumbnailURL(id: Int) -> URL { URL(string: "\(base)/\(id).png")! }
}

enum SpriteCache {
    static var directory: URL { Database.defaultDirectory.appendingPathComponent("sprites", isDirectory: true) }

    static func spriteFile(id: Int, shiny: Bool, in dir: URL = directory) -> URL {
        dir.appendingPathComponent("\(id)\(shiny ? "-shiny" : "").sprite")
    }

    static func thumbnailFile(id: Int, in dir: URL = directory) -> URL {
        dir.appendingPathComponent("thumb-\(id).png")
    }
}

@MainActor
enum SpriteRepository {
    private static func download(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("LLMUsageBar/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 32 else { return nil }
        return data
    }

    private static func store(_ data: Data, at file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Cache-first sprite load; downloads through the fallback chain on a miss.
    static func animation(id: Int, shiny: Bool) async -> SpriteAnimation? {
        let file = SpriteCache.spriteFile(id: id, shiny: shiny)
        if let data = try? Data(contentsOf: file), let anim = SpriteAnimation(data: data, sourceURL: file) {
            return anim
        }
        for url in SpriteSource.candidates(id: id, shiny: shiny) {
            guard let data = await download(url), let anim = SpriteAnimation(data: data, sourceURL: url) else { continue }
            store(data, at: file)
            return anim
        }
        return nil
    }

    static func thumbnail(id: Int) async -> NSImage? {
        let file = SpriteCache.thumbnailFile(id: id)
        if let img = NSImage(contentsOf: file) { return img }
        guard let data = await download(SpriteSource.thumbnailURL(id: id)), let img = NSImage(data: data) else { return nil }
        store(data, at: file)
        return img
    }
}
