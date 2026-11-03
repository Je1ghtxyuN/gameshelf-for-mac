import Foundation
import Darwin
import Security

/// Read-only HTTP/1 resource hosting. The caller persists a nonzero port for a stable origin.
final class GameResourceServer {
    private struct Failure: LocalizedError {
        let status: Int
        var errorDescription: String? { "Game resource server rejected the operation (HTTP \(status))." }
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var stopped = false
        var clients = Set<Int32>()
        var active = 0
        var pending: [(fd: Int32, deadline: TimeInterval)] = []
        let listener: Int32
        let root: String
        let rootFD: Int32
        let token: String
        let port: UInt16
        let workers = DispatchGroup()
        let acceptDone = DispatchSemaphore(value: 0)
        init(listener: Int32, root: String, rootFD: Int32, token: String, port: UInt16) {
            self.listener = listener; self.root = root; self.rootFD = rootFD
            self.token = token; self.port = port
        }
        deinit { Darwin.close(rootFD) }
    }
    private let state: State
    var port: UInt16 { state.port }

    init(root: URL, preferredPort: UInt16 = 0) throws {
        guard root.isFileURL, let resolved = realpath(root.path, nil) else { throw Failure(status: 403) }
        let path = String(cString: resolved); free(resolved)
        let rootFD = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure(status: 403) }
        var success = false
        defer { if !success { Darwin.close(rootFD) } }
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw Failure(status: 500) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        defer { if !success { Darwin.close(fd) } }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = preferredPort.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        guard bound == 0, listen(fd, 128) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { throw POSIXError(.EIO) }
        state = State(listener: fd, root: path, rootFD: rootFD,
                      token: random.map { String(format: "%02x", $0) }.joined(), port: UInt16(bigEndian: addr.sin_port))
        success = true
        let s = state
        DispatchQueue(label: "GameShelf.resources.accept").async { Self.acceptLoop(s) }
    }

    func entryURL(relativePath: String) throws -> URL {
        state.lock.lock(); let stopped = state.stopped; state.lock.unlock()
        guard !stopped else { throw Failure(status: 503) }
        let fd = try Self.openResource(state, relativePath); Darwin.close(fd)
        state.lock.lock(); let stoppedAfterLookup = state.stopped; state.lock.unlock()
        guard !stoppedAfterLookup else { throw Failure(status: 503) }
        var url = URLComponents()
        url.scheme = "http"; url.host = "127.0.0.1"; url.port = Int(port)
        url.path = "/" + state.token + "/" + relativePath
        guard let result = url.url else { throw Failure(status: 400) }
        return result
    }

    func stop() {
        state.lock.lock()
        if state.stopped { state.lock.unlock(); return }
        state.stopped = true
        // Shutdown while descriptors are locked; workers alone close them, preventing fd reuse races.
        for fd in state.clients { shutdown(fd, SHUT_RDWR) }
        state.lock.unlock()
        state.acceptDone.wait()
        // Filesystem calls can block on a disconnected volume; sockets are already shut down.
        _ = state.workers.wait(timeout: .now() + 1)
    }
    deinit { stop() }

    private static func acceptLoop(_ s: State) {
        defer {
            s.lock.lock()
            for item in s.pending { s.clients.remove(item.fd); Darwin.close(item.fd) }
            s.pending.removeAll()
            s.lock.unlock()
            Darwin.close(s.listener); s.acceptDone.signal()
        }
        let queue = DispatchQueue(label: "GameShelf.resources.clients", attributes: .concurrent)
        while true {
            s.lock.lock()
            if s.stopped { s.lock.unlock(); return }
            // A FIFO of descriptors, not blocked threads: at most 16 workers and 128 waiters.
            while let first = s.pending.first, first.deadline <= now() {
                s.pending.removeFirst(); s.clients.remove(first.fd)
                rejectBusy(first.fd)
            }
            while s.active < 16 && !s.pending.isEmpty {
                let fd = s.pending.removeFirst().fd
                s.active += 1; s.workers.enter()
                queue.async {
                    defer {
                        s.lock.lock()
                        s.clients.remove(fd); Darwin.close(fd); s.active -= 1
                        s.lock.unlock(); s.workers.leave()
                    }
                    serve(s, fd)
                }
            }
            s.lock.unlock()
            var p = pollfd(fd: s.listener, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            let fd = accept(s.listener, nil, nil)
            if fd < 0 { continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4)
            s.lock.lock()
            if s.stopped { s.lock.unlock(); Darwin.close(fd); continue }
            if s.pending.count >= 128 { s.lock.unlock(); rejectBusy(fd); continue }
            s.clients.insert(fd)
            // Waiting time is bounded separately from the active request's header/transfer limits.
            s.pending.append((fd, now() + 120))
            s.lock.unlock()
        }
    }

    private static func rejectBusy(_ fd: Int32) {
        // Never block the accept loop on an overloaded peer. Best-effort explicit overload
        // response; an unresponsive peer is closed even if it cannot receive the small header.
        var discard = [UInt8](repeating: 0, count: 16384)
        _ = recv(fd, &discard, discard.count, 0)
        let response = header(503, ["Retry-After": "1"])
        response.withUnsafeBytes { bytes in
            _ = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        }
        shutdown(fd, SHUT_WR); Darwin.close(fd)
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func ready(_ fd: Int32, _ events: Int16, _ deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - now()
            guard remaining > 0 else { throw Failure(status: 408) }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&p, 1, Int32(min(remaining * 1000 + 1, 120_000)))
            if n > 0 { return }
            if n < 0 && errno != EINTR { throw Failure(status: 400) }
        }
    }
    private static func send(_ data: Data, _ fd: Int32, _ deadline: TimeInterval) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(fd, Int16(POLLOUT), deadline)
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { throw Failure(status: 400) }
                offset += n
            }
        }
    }
    private static func header(_ status: Int, _ fields: [String: String] = [:]) -> Data {
        let reasons = [200:"OK",206:"Partial Content",400:"Bad Request",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",408:"Request Timeout",416:"Range Not Satisfiable",431:"Request Header Fields Too Large",500:"Internal Server Error",503:"Service Unavailable"]
        var values = fields
        if values["Content-Length"] == nil { values["Content-Length"] = "0" }
        values["Connection"] = "close"; values["X-Content-Type-Options"] = "nosniff"
        values["Cache-Control"] = "no-store"; values["Referrer-Policy"] = "no-referrer"
        return Data(("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n" + values.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
    }
    private static func serve(_ s: State, _ fd: Int32) {
        var sentHeader = false
        let deadline = now() + 120
        do {
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            let headerDeadline = now() + 5
            while bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
                try ready(fd, Int16(POLLIN), headerDeadline)
                let n = recv(fd, &buffer, buffer.count, 0)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { return }
                bytes.append(contentsOf: buffer.prefix(n))
                guard bytes.count <= 16384 else { throw Failure(status: 431) }
            }
            let end = bytes.range(of: Data("\r\n\r\n".utf8))!.lowerBound
            guard let text = String(data: bytes[..<end], encoding: .utf8) else { throw Failure(status: 400) }
            let lines = text.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard request.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(request[2])) else { throw Failure(status: 400) }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw Failure(status: 400) }
                let name = String(line[..<colon]).lowercased()
                guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), fields[name] == nil else { throw Failure(status: 400) }
                fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard fields["transfer-encoding"] == nil, fields["content-length"] == nil || fields["content-length"] == "0" else { throw Failure(status: 400) }
            guard fields["host"] == "127.0.0.1:\(s.port)" else { throw Failure(status: 403) }
            guard request[0] == "GET" || request[0] == "HEAD" else {
                try send(header(405, ["Allow":"GET, HEAD"]), fd, deadline); return
            }
            let target = String(request[1]).components(separatedBy: "?")[0]
            let prefix = "/" + s.token + "/"
            guard target.hasPrefix(prefix), let relative = String(target.dropFirst(prefix.count)).removingPercentEncoding else { throw Failure(status: 403) }
            let file = try openResource(s, relative); defer { Darwin.close(file) }
            var info = stat(); guard fstat(file, &info) == 0 else { throw Failure(status: 500) }
            let size = Int64(info.st_size)
            var low: Int64 = 0, count = size, status = 200
            var response = ["Content-Type": mime(relative), "Accept-Ranges":"bytes"]
            if let range = fields["range"] {
                guard let bounds = rangeBounds(range, size) else {
                    try send(header(416, ["Content-Range":"bytes */\(size)"]), fd, deadline); return
                }
                low = bounds.0; count = bounds.1 - low + 1; status = 206
                response["Content-Range"] = "bytes \(low)-\(bounds.1)/\(size)"
            }
            response["Content-Length"] = String(count)
            sentHeader = true
            try send(header(status, response), fd, deadline)
            if request[0] == "HEAD" { return }
            var chunk = [UInt8](repeating: 0, count: 65536)
            while count > 0 {
                guard now() < deadline else { return }
                let n = pread(file, &chunk, Int(min(count, 65536)), off_t(low))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                try send(Data(chunk.prefix(n)), fd, deadline)
                low += Int64(n); count -= Int64(n)
            }
        } catch {
            if !sentHeader { try? send(header((error as? Failure)?.status ?? 500), fd, now() + 1) }
        }
    }

    private static func openResource(_ s: State, _ relative: String) throws -> Int32 {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.contains("\\"), !relative.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure(status: 403) }
        do { return try openRelative(s.rootFD, parts, allowLinkFallback: true) }
        catch is LinkFallback { /* Only actual symlinks need absolute canonical resolution. */ }
        guard let resolved = realpath(s.root + "/" + relative, nil) else { throw Failure(status: 404) }
        let path = String(cString: resolved); free(resolved)
        let prefix = s.root == "/" ? "/" : s.root + "/"
        guard path.hasPrefix(prefix) else { throw Failure(status: 403) }
        let canonical = path.dropFirst(prefix.count).split(separator: "/")
        guard !canonical.isEmpty else { throw Failure(status: 403) }
        return try openRelative(s.rootFD, canonical, allowLinkFallback: false)
    }

    private struct LinkFallback: Error {}
    private static func openRelative(_ rootFD: Int32, _ parts: [Substring], allowLinkFallback: Bool) throws -> Int32 {
        var current = dup(rootFD)
        guard current >= 0 else { throw Failure(status: 500) }
        defer { Darwin.close(current) }
        for (index, component) in parts.enumerated() {
            let last = index == parts.count - 1
            let next = openat(current, String(component), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (last ? 0 : O_DIRECTORY))
            if next < 0 {
                let code = errno
                // Darwin can report ELOOP or ENOTDIR for a no-follow directory link.
                // Inspect only failed components; normal NAS paths need no extra stat/realpath.
                if allowLinkFallback && (code == ELOOP || code == ENOTDIR) {
                    var info = stat()
                    if fstatat(current, String(component), &info, AT_SYMLINK_NOFOLLOW) == 0,
                       info.st_mode & S_IFMT == S_IFLNK { throw LinkFallback() }
                }
                throw Failure(status: code == ENOENT ? 404 : 403)
            }
            if last {
                var info = stat()
                guard fstat(next, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { Darwin.close(next); throw Failure(status: 403) }
                return next
            }
            Darwin.close(current); current = next
        }
        throw Failure(status: 403)
    }
    private static func rangeBounds(_ value: String, _ size: Int64) -> (Int64, Int64)? {
        guard size > 0, value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        func number(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(text)
        }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]), suffix > 0 else { return nil }
            return (max(0, size - suffix), size - 1)
        }
        guard let start = number(parts[0]), start < size else { return nil }
        let end: Int64
        if parts[1].isEmpty { end = size - 1 }
        else { guard let parsed = number(parts[1]), parsed >= start else { return nil }; end = min(parsed, size - 1) }
        return (start, end)
    }
    private static func mime(_ path: String) -> String {
        let types = ["html":"text/html; charset=utf-8", "htm":"text/html; charset=utf-8", "js":"application/javascript; charset=utf-8", "mjs":"application/javascript; charset=utf-8", "css":"text/css; charset=utf-8", "json":"application/json; charset=utf-8", "wasm":"application/wasm", "ttf":"font/ttf", "otf":"font/otf", "woff":"font/woff", "woff2":"font/woff2", "ogg":"audio/ogg", "opus":"audio/ogg", "webm":"video/webm", "mp4":"video/mp4", "m4a":"audio/mp4", "mp3":"audio/mpeg", "wav":"audio/wav", "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "svg":"image/svg+xml", "ico":"image/x-icon"]
        return types[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
