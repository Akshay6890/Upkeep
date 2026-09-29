import Foundation

/// Names that indicate credentials, keys or source history. Anything containing
/// one of these is never removed by a rule that asks for sensitive-content detection.
public enum SensitiveNames {
    static let directoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".kube", ".docker", "Keychains",
    ]

    static let fileNames: Set<String> = [
        ".env", ".envrc", ".netrc", ".pgpass", ".npmrc", ".pypirc", ".git-credentials",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials", "known_hosts", "authorized_keys",
    ]

    static let fileExtensions: Set<String> = [
        "keychain", "keychain-db", "p12", "pfx", "kdbx", "gpg", "asc", "ppk",
    ]

    public static func isSensitive(name: String, isDirectory: Bool) -> Bool {
        if isDirectory {
            return directoryNames.contains(name)
        }
        if fileNames.contains(name) { return true }
        if name.hasPrefix(".env.") { return true }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...].lowercased()
            if fileExtensions.contains(ext) { return true }
        }
        return false
    }

    /// Whether any path component names a sensitive directory or file.
    public static func containsSensitiveComponent(_ components: [String]) -> Bool {
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            if directoryNames.contains(component) { return true }
            if isLast && isSensitive(name: component, isDirectory: false) { return true }
        }
        return false
    }
}
