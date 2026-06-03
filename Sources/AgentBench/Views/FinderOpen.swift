import SwiftUI
import AppKit

// Open / reveal produced artifacts in the system. Artifacts live in each lane's
// isolated workspace copy (under Caches); that copy may be purged for old archives,
// so callers gate on `exists` before offering the action.
enum FinderOpen {
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func exists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    // workdir/relative-path → absolute file URL (nil if either is empty)
    static func fileURL(base: String?, rel: String) -> URL? {
        guard let base, !base.isEmpty, !rel.isEmpty else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(rel)
    }
}

extension View {
    // Pointing-hand cursor on hover — signals a row/control is clickable.
    func pointingHand() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
