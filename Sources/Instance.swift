import Foundation

// One at a time.
//
// A second instance is not an accident; it is feedback itself. excludingApplications
// on SCContentFilter works per SCRunningApplication — that is, per process — so a
// second process of the same app is not excluded from the first one's stream. Once
// the two start capturing each other's overlay, the shader is applied to its own
// output every frame and the screen converges on a strange picture. It looks like
// ghosting, but it is not.
//
// The overlay is "the screen looks a bit different", so having launched it twice is
// hard to see. Relying on people being careful will not do; it has to be stopped here.
enum InstanceLock {

    private static var fd: Int32 = -1

    static var path: String { Ident.lockPath }

    /// True if the lock was taken. False if someone already holds it.
    ///
    /// The kernel releases flock when the process dies, so a stale lock file never
    /// survives a crash to block the next run — which is exactly what a PID file
    /// guarantees you will hit.
    static func acquire() -> Bool {
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }   // if we cannot lock, do not block either
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd); fd = -1
            return false
        }
        return true
    }

    /// pids of the other instances holding the lock. Used only in the message.
    static func otherPIDs() -> [Int32] {
        let me = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "MacOS/global-shader"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").compactMap { Int32($0) }.filter { $0 != me }
    }
}
