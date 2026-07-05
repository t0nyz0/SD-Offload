import Foundation
import CryptoKit
import OffloadCore

/// Raw-fd chunked copy/hash loops — the performance core.
///
/// Discipline:
/// - 8 MiB chunks: ~37 syscalls/s at 300 MB/s (overhead invisible), SMB2
///   async-write credits stay full, pause/cancel latency ≤ ~30 ms.
/// - F_NOCACHE on one-pass reads so multi-GB transfers don't evict the page
///   cache (our explicit big reads replace kernel readahead).
/// - F_PREALLOCATE on staging (contiguous APFS extents + up-front ENOSPC);
///   ignored where unsupported (smbfs).
/// - SHA-256 (CryptoKit, ARMv8 SHA-2 instructions — multi-GB/s, never the
///   bottleneck) updated per chunk BEFORE that chunk is written: hop-1 reads
///   are the canonical bytes.
/// - Blocking syscalls run on a GCD utility queue; between chunks we're back
///   in async-land for Task.checkCancellation() + gate parking.
public enum ChunkedIO {
    public static let chunkSize = 8 << 20

    public struct CopyResult: Sendable {
        public let bytes: Int64
        public let sha256Hex: String
    }

    public struct CopyOptions: Sendable {
        public var sourceNoCache = true
        public var preallocate = true
        /// F_FULLFSYNC — only for the afterStagingVerify wipe policy, where the
        /// staged copy becomes the only copy.
        public var fullFsync = false
        public init() {}
    }

    /// One 8 MiB buffer per in-flight file, allocated once and reused across
    /// chunks. The wrapper is what makes the cross-queue captures explicit:
    /// exactly one blocking op touches the buffer at a time.
    private final class ChunkBuffer: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        init() { pointer = .allocate(byteCount: ChunkedIO.chunkSize, alignment: 1 << 12) }
        deinit { pointer.deallocate() }
    }

    // .userInitiated, not .utility: an offload the user is actively watching
    // shouldn't be scheduled at background priority (utility gets throttled hard
    // under Low Power Mode / thermal pressure).
    private static let ioQueue = DispatchQueue(label: "offload.chunkio", qos: .userInitiated, attributes: .concurrent)

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Copy + hash (hop 1 and hop 2 writes)

    /// Copies src → dst (data fork only, no xattrs/AppleDouble), returning the
    /// SHA-256 of the bytes READ. Cleans up dst on cancel/error.
    public static func copyAndHash(from src: URL, to dst: URL,
                                   options: CopyOptions = CopyOptions(),
                                   gate: Gate? = nil,
                                   progress: (@Sendable (Int) -> Void)? = nil) async throws -> CopyResult {
        let srcFD = open(src.path, O_RDONLY)
        guard srcFD >= 0 else { throw OffloadError.posix(errno, stage: "open source") }
        defer { close(srcFD) }
        if options.sourceNoCache { _ = fcntl(srcFD, F_NOCACHE, 1) }

        var st = stat()
        guard fstat(srcFD, &st) == 0 else { throw OffloadError.posix(errno, stage: "stat source") }
        let totalSize = st.st_size

        let dstFD = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard dstFD >= 0 else { throw OffloadError.posix(errno, stage: "open destination") }
        var dstOpen = true
        defer { if dstOpen { close(dstFD) } }

        func cleanupPartial() {
            if dstOpen { close(dstFD); dstOpen = false }
            unlink(dst.path)
        }

        if options.preallocate && totalSize > 0 {
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG), fst_posmode: Int32(F_PEOFPOSMODE),
                                 fst_offset: 0, fst_length: off_t(totalSize), fst_bytesalloc: 0)
            if fcntl(dstFD, F_PREALLOCATE, &store) == -1 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                _ = fcntl(dstFD, F_PREALLOCATE, &store)   // ENOTSUP on smbfs — a hint, not a requirement
            }
        }

        let chunk = ChunkBuffer()
        let buffer = chunk.pointer
        var hasher = SHA256()
        var totalCopied: Int64 = 0

        do {
            while true {
                try Task.checkCancellation()
                if let gate { await gate.whenOpen() }

                let bytesRead = try await blocking { [chunk] () -> Int in
                    while true {
                        let n = read(srcFD, chunk.pointer, chunkSize)
                        if n >= 0 { return n }
                        if errno == EINTR { continue }
                        throw OffloadError.posix(errno, stage: "read source")
                    }
                }
                if bytesRead == 0 { break }

                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))

                try await blocking { [chunk] in
                    var written = 0
                    while written < bytesRead {
                        let n = write(dstFD, chunk.pointer.advanced(by: written), bytesRead - written)
                        if n >= 0 { written += n; continue }
                        if errno == EINTR { continue }
                        throw OffloadError.posix(errno, stage: "write destination")
                    }
                }

                totalCopied += Int64(bytesRead)
                progress?(bytesRead)
            }

            try await blocking {
                guard fsync(dstFD) == 0 else { throw OffloadError.posix(errno, stage: "fsync destination") }
            }
            if options.fullFsync {
                _ = fcntl(dstFD, F_FULLFSYNC)   // ENOTSUP on smbfs; plain fsync above already ran
            }
        } catch {
            cleanupPartial()
            throw error
        }

        let digest = hasher.finalize()
        return CopyResult(bytes: totalCopied, sha256Hex: digest.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Hash (verify passes)

    /// Streams a file into SHA-256. `noCache: true` forces the read from the
    /// medium (or the server, over smbfs), not the local page cache — that is
    /// what makes the verify passes mean something.
    public static func hashFile(_ url: URL, noCache: Bool,
                                gate: Gate? = nil,
                                progress: (@Sendable (Int) -> Void)? = nil) async throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw OffloadError.posix(errno, stage: "open for verify") }
        defer { close(fd) }
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }

        let chunk = ChunkBuffer()
        let buffer = chunk.pointer
        var hasher = SHA256()

        while true {
            try Task.checkCancellation()
            if let gate { await gate.whenOpen() }

            let bytesRead = try await blocking { [chunk] () -> Int in
                while true {
                    let n = read(fd, chunk.pointer, chunkSize)
                    if n >= 0 { return n }
                    if errno == EINTR { continue }
                    throw OffloadError.posix(errno, stage: "read for verify")
                }
            }
            if bytesRead == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))
            progress?(bytesRead)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
