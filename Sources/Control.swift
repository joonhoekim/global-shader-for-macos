import Foundation

// The unix socket the outside uses to talk to the running instance.
//
// Pushing knob values live is the point, and a signal (SIGUSR1) will not do — a value
// has to travel, and an answer has to come back. A script swapping shaders and a
// slider pushing a value go through the same hole.
//
// What crosses it is **always English.** It is read by programs, not people, so an
// answer that changes with a language setting would break anything that branches on it.
//
// One line per connection, one reply, then closed. It holds no state, which makes it
// pleasant to call straight from a shell.
//
//   list                        every knob (JSON)
//   set NAME VALUE              change one
//   reset [NAME]                back to the values in the shader file
//   reload                      re-read the shaders
//   status                      current state (JSON)
//   stop                        quit
enum Control {

    static var socketPath: String { Ident.socketPath }

    private static func makeAddr(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed 104-byte array, which reaches Swift as a tuple.
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let n = Swift.min(bytes.count, raw.count - 1)
            raw.copyBytes(from: bytes[0..<n])
            raw[n] = 0
        }
        return addr
    }

    // MARK: Server

    final class Server {
        private var fd: Int32 = -1
        private var source: DispatchSourceRead?
        private let handler: (String) -> String

        init(handler: @escaping (String) -> String) { self.handler = handler }

        func start() throws {
            let path = Control.socketPath
            // A leftover socket file makes bind fail. This is called after the instance
            // lock has already guaranteed "we are alone", so what is left is dead.
            unlink(path)

            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Errno("socket") }
            var addr = Control.makeAddr(path)
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
            }
            guard ok == 0 else { close(fd); fd = -1; throw Errno("bind \(path)") }
            guard listen(fd, 8) == 0 else { close(fd); fd = -1; throw Errno("listen") }
            chmod(path, 0o600)

            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            s.setEventHandler { [weak self] in self?.accept() }
            s.resume()
            source = s
        }

        private func accept() {
            let c = Darwin.accept(fd, nil, nil)
            guard c >= 0 else { return }
            defer { close(c) }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(c, &buf, buf.count)
            guard n > 0 else { return }
            let line = String(decoding: buf[0..<n], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var reply = handler(line)
            if !reply.hasSuffix("\n") { reply += "\n" }
            _ = reply.withCString { write(c, $0, strlen($0)) }
        }

        func stop() {
            source?.cancel()
            if fd >= 0 { close(fd); fd = -1 }
            unlink(Control.socketPath)
        }
    }

    // MARK: Client

    /// Send one line to the running instance and take the reply. nil if nobody is listening.
    static func send(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = makeAddr(socketPath)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard ok == 0 else { return nil }
        _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Errno: Error, CustomStringConvertible {
        let what: String
        init(_ w: String) { what = w }
        var description: String { "\(what): \(String(cString: strerror(errno)))" }
    }
}
