import Foundation

/// Minimal JSON-RPC client for the local Codex app-server daemon.
///
/// The daemon listens on a Unix socket and speaks WebSocket (text frames, one
/// JSON-RPC message per frame). URLSession can't dial Unix sockets, so the
/// framing is done by hand here. Prototype quality: no fragmentation on send,
/// no compression, no TLS (none is needed on a local socket).
final class CodexClient {
    static let socketPath = NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock"

    /// All callbacks are delivered on the main queue.
    var onNotification: ((String, [String: Any]) -> Void)?
    var onServerRequest: ((Any, String, [String: Any]) -> Void)?
    var onState: ((Bool, String) -> Void)?
    /// The daemon's version, known once connected.
    private(set) var serverVersion: String?

    private var fd: Int32 = -1
    private var nextId = 1
    private var pending: [Int: ([String: Any]?, String?) -> Void] = [:]
    private let lock = NSLock()
    private var readBuffer = [UInt8]()

    func start() {
        Thread.detachNewThread { [weak self] in
            while let self {
                self.runOnce()
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    // MARK: Public API

    func request(_ method: String, _ params: [String: Any] = [:],
                 completion: @escaping ([String: Any]?, String?) -> Void) {
        lock.lock()
        let id = nextId
        nextId += 1
        pending[id] = completion
        lock.unlock()
        if !sendJSON(["id": id, "method": method, "params": params]) {
            finish(id, nil, "not connected")
        }
    }

    func respond(to id: Any, result: [String: Any]) {
        _ = sendJSON(["id": id, "result": result])
    }

    func respondError(to id: Any, message: String) {
        _ = sendJSON(["id": id, "error": ["code": -32601, "message": message]])
    }

    // MARK: Connection

    private func runOnce() {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return report(false, "socket() failed") }
        defer {
            lock.lock()
            if fd == s { fd = -1 }
            let orphans = pending
            pending.removeAll()
            lock.unlock()
            close(s)
            for (_, cb) in orphans { DispatchQueue.main.async { cb(nil, "connection closed") } }
        }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return report(false, "socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            return report(false, "Codex daemon not reachable (is `codex app-server daemon` running?)")
        }

        // WebSocket upgrade.
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { keyBytes[i] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard writeAll(s, Array(handshake.utf8)) else { return report(false, "handshake write failed") }
        readBuffer.removeAll()
        var header = [UInt8]()
        while true {
            guard let b = readExact(s, 1) else { return report(false, "handshake read failed") }
            header.append(b[0])
            if header.count >= 4 && Array(header.suffix(4)) == [13, 10, 13, 10] { break }
            if header.count > 8192 { return report(false, "handshake too large") }
        }
        guard String(decoding: header, as: UTF8.self).contains(" 101 ") else {
            return report(false, "daemon refused WebSocket upgrade")
        }

        lock.lock()
        fd = s
        lock.unlock()

        request("initialize", [
            "clientInfo": ["name": "toplayer", "title": "TopLayer", "version": "0.0.1"],
            "capabilities": ["experimentalApi": true],
        ]) { [weak self] result, error in
            guard let self else { return }
            if let result {
                // The user agent reads "toplayer/0.167.1 (…)": the number is the server's version.
                let agent = result["userAgent"] as? String ?? ""
                self.serverVersion = agent.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(agent[$0]) }
                _ = self.sendJSON(["method": "initialized"])
                self.onState?(true, "connected")
            } else {
                self.onState?(false, error ?? "initialize failed")
            }
        }

        // Read loop.
        var message = [UInt8]()
        while true {
            guard let h = readExact(s, 2) else { break }
            let fin = h[0] & 0x80 != 0
            let opcode = h[0] & 0x0f
            var len = Int(h[1] & 0x7f)
            if len == 126 {
                guard let e = readExact(s, 2) else { break }
                len = Int(e[0]) << 8 | Int(e[1])
            } else if len == 127 {
                guard let e = readExact(s, 8) else { break }
                len = e.reduce(0) { $0 << 8 | Int($1) }
            }
            guard let payload = readExact(s, len) else { break }
            switch opcode {
            case 0x8: return report(false, "daemon closed the connection")
            case 0x9: sendFrame(opcode: 0xA, payload: payload)
            case 0xA: break
            default:
                message.append(contentsOf: payload)
                if fin {
                    handle(Data(message))
                    message.removeAll(keepingCapacity: true)
                }
            }
        }
        report(false, "connection lost, retrying")
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = obj["method"] as? String {
            let params = obj["params"] as? [String: Any] ?? [:]
            if let id = obj["id"] {
                DispatchQueue.main.async { self.onServerRequest?(id, method, params) }
            } else {
                DispatchQueue.main.async { self.onNotification?(method, params) }
            }
        } else if let id = obj["id"] as? Int {
            if let err = obj["error"] as? [String: Any] {
                finish(id, nil, err["message"] as? String ?? "error")
            } else {
                finish(id, obj["result"] as? [String: Any] ?? [:], nil)
            }
        }
    }

    private func finish(_ id: Int, _ result: [String: Any]?, _ error: String?) {
        lock.lock()
        let cb = pending.removeValue(forKey: id)
        lock.unlock()
        if let cb { DispatchQueue.main.async { cb(result, error) } }
    }

    private func report(_ ok: Bool, _ text: String) {
        DispatchQueue.main.async { self.onState?(ok, text) }
    }

    // MARK: Framing

    @discardableResult
    private func sendJSON(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        return sendFrame(opcode: 0x1, payload: [UInt8](data))
    }

    @discardableResult
    private func sendFrame(opcode: UInt8, payload: [UInt8]) -> Bool {
        var frame: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            frame.append(0x80 | UInt8(n))
        } else if n < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8(n >> 8))
            frame.append(UInt8(n & 0xff))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((n >> shift) & 0xff)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.reserveCapacity(frame.count + n)
        for (i, b) in payload.enumerated() { frame.append(b ^ mask[i % 4]) }
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return false }
        return writeAll(fd, frame)
    }

    private func writeAll(_ s: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func readExact(_ s: Int32, _ count: Int) -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while readBuffer.count < count {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 { return nil }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
        let out = Array(readBuffer[0..<count])
        readBuffer.removeFirst(count)
        return out
    }
}
