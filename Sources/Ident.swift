import Foundation

// The one name that identifies this app, and everything derived from it.
//
// Four things have to agree: the LaunchAgent label, the instance lock file, the
// control socket, and the tccutil line in the hint for resetting Screen Recording
// permission. Changing only one of them gives you "the lock is held but the socket
// is somewhere else", which cannot be found from the symptom alone.
//
// The bundle ID itself does not change. It is ordinary reverse-DNS, and changing it
// would split the granted Screen Recording permission, the ~/.config path, and the
// LaunchAgent label all at once.
enum Ident {

    /// Must match CFBundleIdentifier in Info.plist. Run outside the bundle (the bare
    /// binary), Bundle.main cannot supply it, so the constant is the reference.
    static let bundleID = "dev.jh.global-shader"

    /// Label of the LaunchAgent used as the login item, and its plist file name.
    static var agentLabel: String { bundleID }

    /// The lock that keeps it to one at a time. flock, so the kernel releases it on death.
    static var lockPath: String {
        cachePath(bundleID + ".lock")
    }

    /// The unix socket the outside talks to.
    static var socketPath: String {
        cachePath(bundleID + ".sock")
    }

    private static func cachePath(_ name: String) -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches")
        return (dir as NSString).appendingPathComponent(name)
    }
}
