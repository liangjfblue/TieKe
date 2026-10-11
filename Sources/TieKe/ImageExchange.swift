import AppKit
import ImageIO

enum ImageExchangeError: LocalizedError {
    case invalidImage
    case noClipboardImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片。"
        case .noClipboardImage: return "剪贴板中没有可用图片或图片文件。"
        }
    }
}

enum ImageExchange {
    static func load(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageExchangeError.invalidImage
        }
        return image
    }

    static func loadClipboard(_ pasteboard: NSPasteboard = .general) throws -> CGImage {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in urls where url.isFileURL {
            if let image = try? load(url: url) { return image }
        }
        if let image = NSImage(pasteboard: pasteboard),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        throw ImageExchangeError.noClipboardImage
    }

    static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let wrapped = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        return pasteboard.writeObjects([wrapped])
    }

    static func pngData(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ImageExchangeError.invalidImage
        }
        return data
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        try pngData(image).write(to: url, options: .atomic)
    }
}
