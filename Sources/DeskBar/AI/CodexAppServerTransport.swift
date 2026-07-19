import Darwin
import Foundation

enum CodexAppServerError: Error, LocalizedError, Sendable {
    case executableNotFound
    case launchFailed
    case timedOut
    case invalidResponse
    case serverRejected

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI is not installed or is not available to DeskBar."
        case .launchFailed, .timedOut, .invalidResponse, .serverRejected:
            "Codex rate limits are temporarily unavailable."
        }
    }
}

protocol CodexAppServerTransport: Sendable {
    /// Returns the complete JSON-RPC response for `account/rateLimits/read`.
    /// Implementations must not surface stderr or raw server errors to the UI.
    func readRateLimits() async throws -> Data
}

struct LocalCodexAppServerTransport: CodexAppServerTransport {
    private let executableURL: @Sendable () -> URL?
    private let arguments: [String]
    private let processStarted: @Sendable (pid_t) -> Void

    init(
        executableURL: @escaping @Sendable () -> URL? = { CodexExecutableResolver.resolve() },
        arguments: [String] = ["app-server", "--stdio"],
        processStarted: @escaping @Sendable (pid_t) -> Void = { _ in }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.processStarted = processStarted
    }

    func readRateLimits() async throws -> Data {
        guard let executableURL = executableURL() else {
            throw CodexAppServerError.executableNotFound
        }

        let session = CodexAppServerSession(
            executableURL: executableURL,
            arguments: arguments,
            processStarted: processStarted
        )
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try session.exchangeRateLimits()
            }.value
        } onCancel: {
            session.close()
        }
    }
}

enum CodexExecutableResolver {
    private static let approvedPaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex"
    ]

    static func resolve(
        approvedPaths: [String] = approvedPaths,
        fileManager: FileManager = .default
    ) -> URL? {
        var seenTargets = Set<String>()
        for path in approvedPaths {
            let target = URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let normalizedTarget = target.path
            var isDirectory: ObjCBool = false
            guard seenTargets.insert(normalizedTarget).inserted,
                  fileManager.fileExists(atPath: normalizedTarget, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: normalizedTarget) else {
                continue
            }
            return target
        }
        return nil
    }
}

enum CodexProcessEnvironment {
    static let safeExecutablePath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ].joined(separator: ":")

    static func make(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        [
            // HOME lets app-server use the existing Codex login. DeskBar never opens or parses
            // that credential store itself.
            "HOME": homeDirectory.standardizedFileURL.path,
            "TMPDIR": temporaryDirectory.standardizedFileURL.path,
            "PATH": safeExecutablePath,
            "LANG": "en_US.UTF-8"
        ]
    }
}

private final class CodexAppServerSession: @unchecked Sendable {
    private static let initializeRequestID = 1
    private static let rateLimitsRequestID = 2
    private static let maximumLineBytes = 1_048_576

    private let lifecycleLock = NSLock()
    private var didClose = false
    private var readBuffer = Data()
    private var childProcessIdentifier: pid_t = -1
    private var masterFileDescriptor: Int32 = -1

    private let processStarted: @Sendable (pid_t) -> Void
    private let executablePathPointer: UnsafeMutablePointer<CChar>
    private let argumentPointers: [UnsafeMutablePointer<CChar>]
    private let argumentVector: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let environmentPointers: [UnsafeMutablePointer<CChar>]
    private let environmentVector: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

    init(
        executableURL: URL,
        arguments: [String],
        processStarted: @escaping @Sendable (pid_t) -> Void
    ) {
        self.processStarted = processStarted
        let executablePathPointer = strdup(executableURL.path).unsafelyUnwrapped
        let argumentPointers = [executablePathPointer] + arguments.map {
            strdup($0).unsafelyUnwrapped
        }
        let argumentVector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: argumentPointers.count + 1
        )
        for (index, pointer) in argumentPointers.enumerated() {
            argumentVector[index] = pointer
        }
        argumentVector[argumentPointers.count] = nil

        let environmentPointers = CodexProcessEnvironment.make().map {
            strdup("\($0.key)=\($0.value)").unsafelyUnwrapped
        }
        let environmentVector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: environmentPointers.count + 1
        )
        for (index, pointer) in environmentPointers.enumerated() {
            environmentVector[index] = pointer
        }
        environmentVector[environmentPointers.count] = nil

        self.executablePathPointer = executablePathPointer
        self.argumentPointers = argumentPointers
        self.argumentVector = argumentVector
        self.environmentPointers = environmentPointers
        self.environmentVector = environmentVector
    }

    deinit {
        argumentVector.deallocate()
        environmentVector.deallocate()
        argumentPointers.forEach { free($0) }
        environmentPointers.forEach { free($0) }
    }

    func exchangeRateLimits() throws -> Data {
        lifecycleLock.lock()
        guard !didClose else {
            lifecycleLock.unlock()
            throw CancellationError()
        }
        do {
            try launch()
            processStarted(childProcessIdentifier)
        } catch {
            lifecycleLock.unlock()
            throw CodexAppServerError.launchFailed
        }
        let workerFileDescriptor = Darwin.dup(masterFileDescriptor)
        guard workerFileDescriptor >= 0 else {
            lifecycleLock.unlock()
            close()
            throw CodexAppServerError.launchFailed
        }
        lifecycleLock.unlock()

        defer {
            Darwin.close(workerFileDescriptor)
            close()
        }

        try write(
            [
                "id": Self.initializeRequestID,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "deskbar",
                        "title": "DeskBar",
                        "version": "0.1.0"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ],
            fileDescriptor: workerFileDescriptor
        )
        _ = try response(for: Self.initializeRequestID, fileDescriptor: workerFileDescriptor)

        try write(["method": "initialized", "params": [:]], fileDescriptor: workerFileDescriptor)
        try write(
            [
                "id": Self.rateLimitsRequestID,
                "method": "account/rateLimits/read",
                "params": NSNull()
            ],
            fileDescriptor: workerFileDescriptor
        )
        return try response(for: Self.rateLimitsRequestID, fileDescriptor: workerFileDescriptor)
    }

    func close() {
        lifecycleLock.lock()
        guard !didClose else {
            lifecycleLock.unlock()
            return
        }
        didClose = true
        let processIdentifier = childProcessIdentifier
        let masterFileDescriptor = masterFileDescriptor
        childProcessIdentifier = -1
        self.masterFileDescriptor = -1
        lifecycleLock.unlock()

        if masterFileDescriptor >= 0 {
            Darwin.close(masterFileDescriptor)
        }
        guard processIdentifier > 0 else { return }
        Darwin.kill(processIdentifier, SIGTERM)
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier || (result == -1 && errno == ECHILD) { return }
            if result == -1, errno != EINTR { return }
            usleep(10_000)
        }
        Darwin.kill(processIdentifier, SIGKILL)
        while true {
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier || (result == -1 && errno != EINTR) { return }
        }
    }

    private func launch() throws {
        var terminalSettings = termios()
        cfmakeraw(&terminalSettings)
        var windowSize = winsize(ws_row: 24, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let child = forkpty(&master, nil, &terminalSettings, &windowSize)
        guard child >= 0 else { throw CodexAppServerError.launchFailed }

        if child == 0 {
            _ = execve(executablePathPointer, argumentVector, environmentVector)
            _exit(127)
        }

        childProcessIdentifier = child
        masterFileDescriptor = master
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
    }

    private func write(_ object: [String: Any], fileDescriptor: Int32) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerError.invalidResponse
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw CodexAppServerError.invalidResponse
                }
            }
        }
    }

    private func response(for requestID: Int, fileDescriptor: Int32) throws -> Data {
        while true {
            let line = try readLine(fileDescriptor: fileDescriptor)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let responseID = (object["id"] as? NSNumber)?.intValue,
                  responseID == requestID else {
                // Notifications and responses to server-originated requests are irrelevant to
                // this short-lived, read-only bridge.
                continue
            }
            guard object["error"] == nil else {
                throw CodexAppServerError.serverRejected
            }
            guard object["result"] != nil else {
                throw CodexAppServerError.invalidResponse
            }
            return line
        }
    }

    private func readLine(fileDescriptor: Int32) throws -> Data {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = poll(&descriptor, 1, 100)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerError.invalidResponse
            }
            if pollResult == 0 {
                if isClosed() { throw CancellationError() }
                continue
            }

            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CodexAppServerError.invalidResponse
            }
            guard count > 0 else {
                throw CodexAppServerError.invalidResponse
            }
            let chunk = Data(bytes.prefix(count))
            guard readBuffer.count + chunk.count <= Self.maximumLineBytes else {
                throw CodexAppServerError.invalidResponse
            }
            readBuffer.append(chunk)
        }
    }

    private func isClosed() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return didClose
    }
}
