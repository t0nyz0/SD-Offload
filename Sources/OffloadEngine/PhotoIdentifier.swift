import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import OffloadCore

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
        case noAPIKey
        case apiError(String)
        public var errorDescription: String? {
            switch self {
            case .cliNotFound: return "Couldn't find the `claude` CLI. Install Claude Code and sign in, or switch to API mode in Settings."
            case .previewFailed: return "Couldn't read the photo to analyze."
            case .cliFailed(let m): return "Claude couldn't analyze the photo: \(m)"
            case .unparseable(let m): return "Claude's answer wasn't in the expected form: \(m)"
            case .timedOut: return "Analysis timed out. Try again."
            case .noAPIKey: return "No Anthropic API key set. Add one in Settings → AI, or switch to CLI mode."
            case .apiError(let m): return "Anthropic API error: \(m)"
            }
        }
    }

    let provider: AIProvider
    let apiKey: String?
    let model: String
    let binaryPath: String?
    let timeout: TimeInterval
    public init(provider: AIProvider = .cli, apiKey: String? = nil, model: String = "",
                binaryPath: String? = nil, timeout: TimeInterval = 90) {
        self.provider = provider
        let k = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (k?.isEmpty == false) ? k : nil
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let text: String
        switch provider {
        case .cli: text = try await identifyViaCLI(temp)
        case .api: text = try await identifyViaAPI(temp)
        }
        return try Self.parse(text)
    }

    private func identifyViaCLI(_ temp: URL) async throws -> String {
        let exe = try resolveBinary()
        let full = Self.prompt + "\n\nRead the image at this absolute path with your Read tool, then answer: \(temp.path)"
        let dir = temp.deletingLastPathComponent().path
        let args = ["-p", full, "--output-format", "text", "--add-dir", dir, "--allowedTools", "Read"]
        return try await runWithTimeout(exe, args)
    }

    /// Anthropic Messages API with an inline base64 image. Raw HTTP (no SDK) — one
    /// request, plain JSON. Uses the user's own key.
    private func identifyViaAPI(_ temp: URL) async throws -> String {
        guard let key = apiKey else { throw IDError.noAPIKey }
        let b64 = try Data(contentsOf: temp).base64EncodedString()
        let mdl = model.isEmpty ? "claude-opus-4-5" : model
        let body: [String: Any] = [
            "model": mdl,
            "max_tokens": 500,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
                    ["type": "text", "text": Self.prompt],
                ],
            ]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw IDError.apiError("no response") }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw IDError.apiError(msg)
        }
        let content = obj?["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw IDError.apiError("empty response") }
        return text
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

    private static let cachedBinary = ResolvedBinary()

    private func resolveBinary() throws -> String {
        let fm = FileManager.default
        if let p = binaryPath, fm.isExecutableFile(atPath: p) { return p }
        // Discovery spawns a login shell — cache it once per process instead of doing
        // it for every photo in a batch.
        if let hit = Self.cachedBinary.get() { return hit }
        var found: String?
        if let f = Self.loginShellWhich(), fm.isExecutableFile(atPath: f) { found = f }
        else {
            let home = NSHomeDirectory()
            found = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude",
                     "\(home)/.claude/local/claude", "/usr/bin/claude"].first { fm.isExecutableFile(atPath: $0) }
        }
        guard let path = found else { throw IDError.cliNotFound }
        Self.cachedBinary.set(path)
        return path
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

/// Process-wide cache of the discovered `claude` path (discovery spawns a shell).
private final class ResolvedBinary: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return path }
    func set(_ p: String) { lock.lock(); path = p; lock.unlock() }
}
