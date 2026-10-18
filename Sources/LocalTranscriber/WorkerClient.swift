import Foundation

public enum WorkerClientError: Error, LocalizedError {
    case pythonNotFound
    case workerScriptNotFound
    case launchFailed(String)
    case handshakeFailed(String)
    case timeout(String)
    case communicationError(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Could not find a valid Python 3 binary for worker execution."
        case .workerScriptNotFound:
            return "Could not locate transcriber-worker/worker.py."
        case .launchFailed(let msg):
            return "Failed to launch Python worker process: \(msg)"
        case .handshakeFailed(let msg):
            return "Handshake with Python worker failed: \(msg)"
        case .timeout(let msg):
            return "Worker timed out: \(msg)"
        case .communicationError(let msg):
            return "Worker communication failed: \(msg)"
        case .serverError(let msg):
            return "Worker reported error: \(msg)"
        }
    }
}

private actor RequestSerializer {
    func run<T>(_ operation: () async throws -> T) async throws -> T {
        try await operation()
    }
}

public final class WorkerClient {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutHandle: FileHandle
    private let stdinHandle: FileHandle
    private let stderrHandle: FileHandle
    private var buffer = Data()
    private var stderrBuffer = Data()
    private let lock = NSLock()
    private var isTerminated = false
    private let serializer = RequestSerializer()

    public let chunkTimeout: TimeInterval = {
        if let env = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_CHUNK_TIMEOUT"],
           let val = TimeInterval(env) {
            return val
        }
        return 90.0
    }()

    public let finalTimeout: TimeInterval = {
        if let env = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_FINAL_TIMEOUT"],
           let val = TimeInterval(env) {
            return val
        }
        return 1200.0
    }()

    public static func resolveProjectRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_HOME"], !env.isEmpty {
            let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("transcriber-worker/worker.py").path) {
                return url
            }
        }

        // Check executable path (resolving symlinks)
        if let execURL = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var cur = execURL.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = cur.appendingPathComponent("transcriber-worker").appendingPathComponent("worker.py")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return cur
                }
                cur = cur.deletingLastPathComponent()
            }
        }

        // Standard machine locations
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardCandidates = [
            home.appendingPathComponent("Documents").appendingPathComponent("local-transcriber"),
            home.appendingPathComponent(".local").appendingPathComponent("share").appendingPathComponent("local-transcriber")
        ]
        for candidate in standardCandidates {
            let workerFile = candidate.appendingPathComponent("transcriber-worker").appendingPathComponent("worker.py")
            if FileManager.default.fileExists(atPath: workerFile.path) {
                return candidate
            }
        }

        return nil
    }

    public static func resolvePythonPath() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_PYTHON"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }

        // Check project root venv
        if let root = resolveProjectRoot() {
            let venvPy = root.appendingPathComponent("transcriber-worker").appendingPathComponent(".venv/bin/python").path
            if FileManager.default.isExecutableFile(atPath: venvPy) {
                return venvPy
            }
        }

        // Check relative venv
        let possibleVenvs = [
            "transcriber-worker/.venv/bin/python",
            "../transcriber-worker/.venv/bin/python",
            "../../transcriber-worker/.venv/bin/python"
        ]
        for rel in possibleVenvs {
            let path = rel.hasPrefix("/") ? rel : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Check python3 in PATH
        let paths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
            "/opt/homebrew/Caskroom/miniconda/base/bin/python3"
        ]
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }

        return nil
    }

    public static func resolveWorkerScript() -> String? {
        if let envWorker = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_WORKER"],
           FileManager.default.fileExists(atPath: envWorker) {
            return envWorker
        }

        if let root = resolveProjectRoot() {
            let scriptPath = root.appendingPathComponent("transcriber-worker").appendingPathComponent("worker.py").path
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }

        let candidates = [
            "transcriber-worker/worker.py",
            "../transcriber-worker/worker.py",
            "../../transcriber-worker/worker.py"
        ]
        for candidate in candidates {
            let path = candidate.hasPrefix("/") ? candidate : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    public init(modelOverride: String? = nil) async throws {
        guard let pythonPath = Self.resolvePythonPath() else {
            throw WorkerClientError.pythonNotFound
        }
        guard let scriptPath = Self.resolveWorkerScript() else {
            throw WorkerClientError.workerScriptNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        if let model = modelOverride {
            env["LOCAL_TRANSCRIBER_MODEL"] = model
        }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading

        self.stdoutHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self = self else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            self.lock.unlock()
        }

        self.stderrHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self = self else { return }
            self.lock.lock()
            self.stderrBuffer.append(chunk)
            self.lock.unlock()
        }

        do {
            try proc.run()
        } catch {
            throw WorkerClientError.launchFailed(error.localizedDescription)
        }

        // Wait for handshake {"ready": true}
        let handshakeLine = try await readLine(timeout: 60.0)
        guard let lineData = handshakeLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              json["ready"] as? Bool == true else {
            throw WorkerClientError.handshakeFailed("Unexpected ready response: \(handshakeLine)")
        }
    }

    public func ping() async throws {
        let req: [String: Any] = ["command": "ping"]
        let res = try await sendRequest(req, timeout: 5.0)
        guard res["status"] as? String == "ok" else {
            throw WorkerClientError.serverError("Ping response was not ok")
        }
    }

    public func transcribeChunk(audioURL: URL, source: String, language: String, task: String, discardBefore: Double) async throws -> [TranscriptSegment] {
        let req: [String: Any] = [
            "command": "transcribe_chunk",
            "audio_path": audioURL.path,
            "source": source,
            "language": language,
            "task": task,
            "discard_before": discardBefore
        ]
        return try await executeTranscribeRequest(req, timeout: chunkTimeout)
    }

    public func transcribeFile(audioURL: URL, source: String, language: String, task: String) async throws -> [TranscriptSegment] {
        let req: [String: Any] = [
            "command": "transcribe_file",
            "audio_path": audioURL.path,
            "source": source,
            "language": language,
            "task": task
        ]
        return try await executeTranscribeRequest(req, timeout: finalTimeout)
    }

    private func executeTranscribeRequest(_ req: [String: Any], timeout: TimeInterval) async throws -> [TranscriptSegment] {
        let res = try await sendRequest(req, timeout: timeout)
        let status = res["status"] as? String
        if status != "ok" {
            let msg = res["message"] as? String ?? "Unknown worker error"
            throw WorkerClientError.serverError(msg)
        }

        guard let rawSegments = res["segments"] as? [[String: Any]] else {
            return []
        }

        var segments = [TranscriptSegment]()
        for item in rawSegments {
            guard let start = item["start"] as? Double,
                  let end = item["end"] as? Double,
                  let text = item["text"] as? String,
                  let source = item["source"] as? String else {
                continue
            }
            segments.append(TranscriptSegment(start: start, end: end, text: text, source: source))
        }
        return segments
    }

    private func sendRequest(_ req: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await serializer.run {
            let (isClosed, isRunning) = self.lock.withLock {
                (self.isTerminated, self.process.isRunning)
            }
            guard !isClosed && isRunning else {
                throw WorkerClientError.communicationError("Worker client is terminated or not running")
            }

            let jsonData = try JSONSerialization.data(withJSONObject: req, options: [])
            var lineData = jsonData
            lineData.append(contentsOf: [0x0A]) // \n

            do {
                try self.stdinHandle.write(contentsOf: lineData)
            } catch {
                throw WorkerClientError.communicationError("Failed to write to worker stdin: \(error.localizedDescription)")
            }

            let responseLine = try await self.readLine(timeout: timeout)
            guard let respData = responseLine.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                throw WorkerClientError.communicationError("Failed to parse JSON response: \(responseLine)")
            }
            return dict
        }
    }

    private func readLine(timeout: TimeInterval) async throws -> String {
        let startTime = Date()

        while true {
            let (isClosed, isRunning) = lock.withLock {
                (isTerminated, process.isRunning)
            }
            if isClosed {
                throw WorkerClientError.communicationError("Worker client was terminated")
            }

            let extractedLine: String? = lock.withLock {
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: 0..<newlineIndex)
                    buffer.removeSubrange(0...newlineIndex)
                    if let lineStr = String(data: lineData, encoding: .utf8) {
                        return lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return nil
            }

            if let line = extractedLine {
                return line
            }

            if Date().timeIntervalSince(startTime) > timeout {
                let errOutput = getStderrString().trimmingCharacters(in: .whitespacesAndNewlines)
                if !errOutput.isEmpty {
                    throw WorkerClientError.timeout("Timed out waiting for response line after \(timeout)s. Worker stderr: \(errOutput)")
                } else {
                    throw WorkerClientError.timeout("Timed out waiting for response line after \(timeout)s")
                }
            }

            // Check if process terminated unexpectedly
            if !isRunning {
                let errOutput = getStderrString().trimmingCharacters(in: .whitespacesAndNewlines)
                let exitCode = process.terminationStatus
                if !errOutput.isEmpty {
                    throw WorkerClientError.communicationError("Worker process terminated prematurely (exit code \(exitCode)): \(errOutput)")
                } else {
                    throw WorkerClientError.communicationError("Worker process terminated prematurely (exit code \(exitCode))")
                }
            }

            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    private func getStderrString() -> String {
        lock.withLock {
            String(data: stderrBuffer, encoding: .utf8) ?? ""
        }
    }

    public func terminate() {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return
        }
        isTerminated = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdinHandle.close()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    deinit {
        terminate()
    }
}
