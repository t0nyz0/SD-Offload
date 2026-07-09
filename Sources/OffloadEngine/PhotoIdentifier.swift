import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Fine-grained photo identification via the local `claude` CLI (Claude Code). Uses
/// your logged-in Claude session — no API key, no metered billing — the same way you
/// would in a terminal (`claude -p …`). Sends a downsized copy of the photo (cheap to
/// read + transmit) and gets back a description plus SPECIFIC tags (species, models,
/// scene types) that Apple's on-device classifier can't produce. On-demand only.
public struct PhotoIdentifier: Sendable {
    public struct Identification: Sendable, Codable, Equatable {
        public let description: String
        public let tags: [String]
        public init(description: String, tags: [String]) { self.description = description; self.tags = tags }
    }

    public enum IDError: Error, LocalizedError {
        case cliNotFound
        case previewFailed
        case cliFailed(String)
        case unparseable(String)
        case timedOut
        public var errorDescription: String? {
            switch self {
            case .cliNotFound: return "Couldn't find the `claude` CLI. Install Claude Code and sign in, then try again."
            case .previewFailed: return "Couldn't read the photo to analyze."
            case .cliFailed(let m): return "Claude couldn't analyze the photo: \(m)"
            case .unparseable(let m): return "Claude's answer wasn't in the expected form: \(m)"
            case .timedOut: return "Analysis timed out. Try again."
            }
        }
    }

    let binaryPath: String?
    let timeout: TimeInterval
    public init(binaryPath: String? = nil, timeout: TimeInterval = 90) {
        let t = binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.binaryPath = (t?.isEmpty == false) ? t : nil
        self.timeout = timeout
    }

    private static let prompt = """
    Identify what this photo actually shows. Be specific and confident: name the main \
    subject and its exact type — species for a plant or animal, make/model for a \
    vehicle, the kind of place for a scene (e.g. "boutique hotel lobby", not just \
    "building"). Note other notable objects and the setting.
    Respond ONLY with compact JSON, no prose, no markdown fences:
    {"description":"one natural sentence describing the photo","tags":["specific tag","more tags"]}
    Use 4-8 tags, most specific first.
    """

    public func identify(imageURL: URL) async throws -> Identification {
        let temp = try Self.makeTempPreview(imageURL)
        defer { try? FileManager.default.removeItem(at: temp) }
        let exe = try resolveBinary()
        let full = Self.prompt + "\n\nRead the image at this absolute path with your Read tool, then answer: \(temp.path)"
        let dir = temp.deletingLastPathComponent().path
        let args = ["-p", full, "--output-format", "text", "--add-dir", dir, "--allowedTools", "Read"]
        let out = try await runWithTimeout(exe, args)
        return try Self.parse(out)
    }

    // MARK: - Downsize (cheap to read + send; plenty for identification)

    private static func makeTempPreview(_ url: URL, maxPixel: Int = 1024) throws -> URL {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw IDError.previewFailed
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("offload-id-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw IDError.previewFailed
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw IDError.previewFailed }
        return temp
    }

    // MARK: - Parse (tolerate stray prose / markdown fences)

    static func parse(_ text: String) throws -> Identification {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw IDError.unparseable(String(text.prefix(200)))
        }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONDecoder().decode(Identification.self, from: data) else {
            throw IDError.unparseable(String(text.prefix(200)))
        }
        let tags = obj.tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let desc = obj.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty || !tags.isEmpty else { throw IDError.unparseable("empty result") }
        return Identification(description: desc, tags: tags)
    }

    // MARK: - Subprocess

    private func runWithTimeout(_ exe: String, _ args: [String]) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await Self.run(exe, args) }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw IDError.timedOut }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func resolveBinary() throws -> String {
        let fm = FileManager.default
        if let p = binaryPath, fm.isExecutableFile(atPath: p) { return p }
        if let f = Self.loginShellWhich(), fm.isExecutableFile(atPath: f) { return f }
        let home = NSHomeDirectory()
        for c in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude",
                  "\(home)/.claude/local/claude", "/usr/bin/claude"] where fm.isExecutableFile(atPath: c) { return c }
        throw IDError.cliNotFound
    }

    private static func loginShellWhich() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Spawn `claude`, capture stdout, and — critically — kill the child if the Swift
    /// task is cancelled (our timeout), so an orphaned CLI can't keep burning the plan.
    private static func run(_ exe: String, _ args: [String]) async throws -> String {
        let box = ProcBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: exe)
                proc.arguments = args
                proc.currentDirectoryURL = FileManager.default.temporaryDirectory
                // GUI apps inherit a minimal PATH; give the CLI (a node script) a real
                // one so `node` and its auth resolve.
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                             "\(home)/.claude/local", "/usr/bin", "/bin"]
                env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
                proc.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                let outData = LockedData(), errData = LockedData()
                outPipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { outData.append(d) } }
                errPipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { errData.append(d) } }

                proc.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let out = String(data: outData.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let err = String(data: errData.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if box.wasCancelled { cont.resume(throwing: CancellationError()) }
                    else if p.terminationStatus != 0 { cont.resume(throwing: IDError.cliFailed(err.isEmpty ? out : err)) }
                    else if out.isEmpty { cont.resume(throwing: IDError.cliFailed("no output")) }
                    else { cont.resume(returning: out) }
                }

                box.attach(proc)
                do { try proc.run() } catch { box.detach(); cont.resume(throwing: IDError.cliNotFound); return }
                if Task.isCancelled { box.terminate() }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Holds the in-flight child so a task cancellation (timeout) can terminate it
/// instead of leaving `claude` orphaned against the plan's rate limit.
private final class ProcBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var cancelled = false
    func attach(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
    func detach() { lock.lock(); proc = nil; lock.unlock() }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func terminate() {
        lock.lock(); cancelled = true; let p = proc; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

private final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
