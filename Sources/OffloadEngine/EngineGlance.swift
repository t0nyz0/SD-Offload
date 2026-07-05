import Foundation
import OffloadCore

/// Cheap, synchronous NAS overview for the UI (popover glance row, Library
/// header). Full health semantics live in NASLocator; this is the read-only
/// subset safe to call from anywhere.
public enum EngineGlance {
    public static func quickNASGlance(config: AppConfig) -> NASGlance {
        let path = config.nasRootPath
        guard FileManager.default.fileExists(atPath: path),
              let info = statfsInfo(path: path) else {
            return NASGlance(mounted: false, healthy: false)
        }
        // A network filesystem mounted exactly at our root — anything else
        // (apfs on "/", wrong share) is not a healthy destination.
        let isNetworkFS = ["smbfs", "afpfs", "nfs", "webdav"].contains(info.fsTypeName)
            || config.testAllowLocalNAS
        let identityOK: Bool = {
            guard let expected = config.nasExpectedMntFromName else { return true } // not learned yet
            return info.mntFromName == expected
        }()
        let healthy = isNetworkFS && info.mntOnName == path && identityOK && !info.isReadOnly
        return NASGlance(
            mounted: true,
            healthy: healthy,
            freeBytes: info.freeBytes,
            totalBytes: info.totalBytes,
            photoCount: nil,       // filled by the LibraryIndex (M5)
            photoBytes: nil,
            mntFromName: isNetworkFS ? info.mntFromName : nil
        )
    }
}
