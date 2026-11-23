import AppKit
import Foundation
import TFDomain

/// The only place that touches `NSPasteboard` (SPEC §06 §3).
@MainActor
public final class SystemPasteboard: PasteboardAccessing {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func write(_ content: PasteboardContent) async throws(AppError) {
        pasteboard.clearContents()
        let ok: Bool
        switch content {
        case .string(let text): ok = pasteboard.setString(text, forType: .string)
        case .image(let data): ok = pasteboard.setData(data, forType: .png)
        }
        guard ok else { throw .export(.clipboardWriteFailed) }
    }

    /// Writes PNG plus TIFF so the image pastes into every common app (EXP-03).
    public func writeImage(_ image: PixelImage) async throws(AppError) {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = NSSize(width: image.pointSize.width, height: image.pointSize.height)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw .export(.encodingFailed) }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw .export(.clipboardWriteFailed) }
    }

    public func readString() async -> String? { pasteboard.string(forType: .string) }

    public func changeCount() async -> Int { pasteboard.changeCount }

    public func snapshot() async -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        }
        return PasteboardSnapshot(items: items)
    }

    /// Restores the user's clipboard after synthetic copy/paste (TXT-16).
    public func restore(_ snapshot: PasteboardSnapshot) async {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
