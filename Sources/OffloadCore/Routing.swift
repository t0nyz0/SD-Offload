import Foundation

/// Destination routing — THE v1.1 AI seam. v1 ships only the date router;
/// a future organizer (driven by the `claude` CLI) conforms to the same protocol.
public protocol DestinationRouting: Sendable {
    /// Returns a path relative to the NAS root, e.g. "2026/07/04/DSCF0523.RAF".
    func destinationRelPath(fileName: String, captureDate: Date) -> String
}

public struct DateFolderRouter: DestinationRouting {
    public let layout: DateFolderLayout
    public init(layout: DateFolderLayout = .nestedNumeric) { self.layout = layout }

    public func destinationRelPath(fileName: String, captureDate: Date) -> String {
        layout.destinationRelPath(fileName: fileName, captureDate: captureDate)
    }
}

public enum CollisionPolicy {
    /// "DSCF0001.RAF" → "DSCF0001 (2).RAF", "DSCF0001 (3).RAF", …
    public static func suffixed(_ relPath: String, attempt: Int) -> String {
        let ns = relPath as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let renamed = "\(base) (\(attempt))"
        return ext.isEmpty ? renamed : "\(renamed).\(ext)"
    }
}
