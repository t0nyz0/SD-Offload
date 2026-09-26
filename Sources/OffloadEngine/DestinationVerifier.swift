import Foundation
import OffloadCore

/// Re-read the entire destination manifest before erasing any source file.
/// A recorded success from earlier in the transfer is not sufficient.
public enum DestinationVerifier {
    public static func verify(files: [FileRecord], root: String) async throws {
        guard !files.isEmpty else { throw OffloadError(.internalError("Empty destination manifest")) }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        for file in files {
            guard file.state.recordsNASVerification, let expected = file.sourceHashHex, !expected.isEmpty else {
                throw OffloadError(.internalError("No recorded NAS verification/hash for \(file.relPath)"))
            }
            let url = rootURL.appendingPathComponent(file.destRelPath).standardizedFileURL
            guard !file.destRelPath.hasPrefix("/"),
                  !file.destRelPath.split(separator: "/").contains(".."),
                  url.resolvingSymlinksInPath().path.hasPrefix(rootURL.path + "/"),
                  let st = WipeGate.liveStat(url.path), st.isRegularFile, !st.isSymlink, st.size == file.size else {
                throw OffloadError(.destinationUnwritable("Missing, changed, or invalid destination: \(file.destRelPath)"))
            }
            guard try await ChunkedIO.hashFile(url, noCache: true) == expected else {
                throw OffloadError(.hashMismatch(stage: "final NAS check: \(file.destRelPath)"))
            }
        }
    }
}
