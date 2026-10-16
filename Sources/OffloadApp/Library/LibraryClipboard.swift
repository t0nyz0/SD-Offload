import AppKit

/// Finder-compatible file references, without reading or staging the originals.
/// Finder performs the actual file copy when the user pastes into a folder.
enum LibraryClipboard {
    static func items(in visibleItems: [DisplayItem], selection: Set<String>,
                      clicked: DisplayItem? = nil) -> [DisplayItem] {
        if let clicked, !selection.contains(clicked.id) {
            return clicked.isFolder ? [] : [clicked]
        }
        return visibleItems.filter { !$0.isFolder && selection.contains($0.id) }
    }

    static func urls(for items: [DisplayItem], includingRAW: Bool = false) -> [URL] {
        var seen = Set<URL>()
        return items.filter { !$0.isFolder }.flatMap { item in
            let entries = includingRAW ? [item.primary] + item.all : [item.primary]
            return entries.compactMap { entry in
                let url = URL(fileURLWithPath: entry.id, isDirectory: false)
                return seen.insert(url).inserted ? url : nil
            }
        }
    }

    @MainActor @discardableResult
    static func copy(_ items: [DisplayItem], includingRAW: Bool = false,
                     to pasteboard: NSPasteboard = .general) -> Bool {
        let files = urls(for: items, includingRAW: includingRAW)
        // An empty/stale selection must not erase whatever the user last copied.
        guard !files.isEmpty else { return false }
        pasteboard.clearContents()
        // NSURL writes public.file-url, which Finder treats as original files,
        // rather than path text or a rendered thumbnail. No filesystem calls here.
        return pasteboard.writeObjects(files.map { $0 as NSURL })
    }
}
