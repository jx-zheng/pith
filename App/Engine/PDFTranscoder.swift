import AppKit
import Foundation
import PDFKit
import PithCore

enum PDFTranscoder {
    static func renderPages(
        source: URL,
        format: FileType,
        dpi: Double,
        location: OutputLocation,
        quality: Double?,
        exists: @escaping (String) -> Bool
    ) throws -> [URL] {
        guard let document = PDFDocument(url: source) else {
            throw ConversionFailure.unreadable("Couldn't open \(source.lastPathComponent) as a PDF.")
        }
        guard document.pageCount > 0 else {
            throw ConversionFailure.unreadable("The PDF has no pages.")
        }
        let scale = CGFloat(dpi / 72.0)
        var written: [String] = []
        var urls: [URL] = []
        let combined: (String) -> Bool = { exists($0) || written.contains($0) }
        for index in 0..<document.pageCount {
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let bounds = page.bounds(for: .mediaBox)
                let width = max(1, Int((bounds.width * scale).rounded()))
                let height = max(1, Int((bounds.height * scale).rounded()))
                guard let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    throw ConversionFailure.writeFailed("Couldn't allocate a page bitmap.")
                }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.saveGState()
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()
                guard let image = context.makeImage() else {
                    throw ConversionFailure.writeFailed("Couldn't render page \(index + 1).")
                }
                let path = OutputNamer.destination(
                    sourcePath: source.path,
                    outputExtension: format.primaryExtension,
                    location: location,
                    style: .page(number: index + 1, count: document.pageCount),
                    exists: combined
                )
                let url = URL(fileURLWithPath: path)
                try ImageIOBridge.write(image, to: url, uti: format.uti, quality: quality)
                written.append(path)
                urls.append(url)
            }
        }
        return urls
    }

    static func extractText(source: URL, destination: URL) throws -> [URL] {
        guard let document = PDFDocument(url: source) else {
            throw ConversionFailure.unreadable("Couldn't open \(source.lastPathComponent).")
        }
        let text = document.string ?? ""
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return [destination]
    }

    /// PDF → DOCX without LibreOffice: each page's text (with PDFKit's basic styling) as one Word document.
    static func toDocx(source: URL, destination: URL) throws -> [URL] {
        guard let document = PDFDocument(url: source) else {
            throw ConversionFailure.unreadable("Couldn't open \(source.lastPathComponent).")
        }
        let combined = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let text = document.page(at: index)?.attributedString else { return }
                if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
                combined.append(text)
            }
        }
        let data = try combined.data(
            from: NSRange(location: 0, length: combined.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: destination, options: .atomic)
        return [destination]
    }

    static func imageToPDF(image: CGImage, destination: URL) throws -> [URL] {
        let maxSide: CGFloat = 11 * 72
        let longEdge = CGFloat(max(image.width, image.height))
        let scale = min(1, maxSide / max(longEdge, 1))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let nsImage = NSImage(cgImage: image, size: size)
        guard let page = PDFPage(image: nsImage) else {
            throw ConversionFailure.writeFailed("Couldn't build a PDF page.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: destination) else {
            throw ConversionFailure.writeFailed("Couldn't write \(destination.lastPathComponent).")
        }
        return [destination]
    }

    static func merge(sources: [URL], destination: URL) throws -> [URL] {
        let document = PDFDocument()
        for source in sources {
            try autoreleasepool {
                if source.pathExtension.lowercased() != "pdf" {
                    // Images become one page each, sized to the image.
                    guard let image = NSImage(contentsOf: source), let page = PDFPage(image: image) else {
                        throw ConversionFailure.unreadable("Couldn't open \(source.lastPathComponent).")
                    }
                    document.insert(page, at: document.pageCount)
                    return
                }
                guard let piece = PDFDocument(url: source) else {
                    throw ConversionFailure.unreadable("Couldn't open \(source.lastPathComponent).")
                }
                for index in 0..<piece.pageCount {
                    autoreleasepool {
                        if let page = piece.page(at: index) {
                            document.insert(page, at: document.pageCount)
                        }
                    }
                }
            }
        }
        guard document.pageCount > 0, document.write(to: destination) else {
            throw ConversionFailure.writeFailed("Couldn't write the merged PDF.")
        }
        return [destination]
    }

    static func split(source: URL, location: OutputLocation, exists: @escaping (String) -> Bool) throws -> [URL] {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw ConversionFailure.unreadable("Couldn't open \(source.lastPathComponent).")
        }
        var written: [String] = []
        var urls: [URL] = []
        for index in 0..<document.pageCount {
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let piece = PDFDocument()
                piece.insert(page, at: 0)
                let path = OutputNamer.destination(
                    sourcePath: source.path,
                    outputExtension: "pdf",
                    location: location,
                    style: .page(number: index + 1, count: document.pageCount),
                    exists: { exists($0) || written.contains($0) }
                )
                let url = URL(fileURLWithPath: path)
                guard piece.write(to: url) else {
                    throw ConversionFailure.writeFailed("Couldn't write \(url.lastPathComponent).")
                }
                written.append(path)
                urls.append(url)
            }
        }
        return urls
    }
}
