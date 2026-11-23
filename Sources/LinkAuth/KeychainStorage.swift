import Foundation
import Security
import LocalAuthentication
import Darwin
#if canImport(LinkAuthCore)
import LinkAuthCore
#endif

// Internal seam for tests. Production always uses the system Keychain backend.
protocol KeychainBackend {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
    func delete(service: String, account: String) throws
}

private struct SystemKeychain: KeychainBackend {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    func read(service: String, account: String) throws -> Data? {
        var request = query(service, account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageFailure.Unavailable }
        return data
    }
    func write(service: String, account: String, data: Data) throws {
        let request = query(service, account)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageFailure.Unavailable }
    }
    func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageFailure.Unavailable }
    }
}

/// Device-only, non-synchronizing Keychain records, addressed through an
/// installation ID excluded from backups. A restored/reinstalled app cannot
/// select old Keychain journals. Locked/unavailable storage is an error.
/// Holds the session journal (`link.auth.v1.*`) and the record of the attested
/// key (`link.attest.v1.*`); App Attest keys do not survive a reinstall either.
public final class KeychainStorage: SecureStorage, @unchecked Sendable {
    private struct Envelope: Codable { let revision: String; let payload: String }
    private static let localGate = NSLock()
    private let service: String
    private let directory: URL
    private let backend: KeychainBackend

    public convenience init(service: String) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        try self.init(service: service, directory: support.appendingPathComponent("LinkAuthLocks", isDirectory: true), backend: SystemKeychain())
    }

    init(service: String, directory: URL, backend: KeychainBackend) throws {
        guard !service.isEmpty && service.utf8.count <= 256 else { throw StorageFailure.Unavailable }
        self.service = service; self.directory = directory; self.backend = backend
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var url = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { throw StorageFailure.Unavailable }
    }

    public func load(key: String) throws -> StorageEntry? {
        try transaction(key) { try read(key) }
    }

    public func compareExchange(key: String, expectedRevision: String?, replacement: StorageEntry?) throws -> Bool {
        try transaction(key) {
            guard try read(key)?.revision() == expectedRevision else { return false }
            if let replacement {
                let revision = replacement.revision(), payload = replacement.payload()
                guard revision.count == 43 && payload.utf8.count <= 65_536 else { throw StorageFailure.Unavailable }
                let bytes = try JSONEncoder().encode(Envelope(revision: revision, payload: payload))
                try backend.write(service: service, account: account(key), data: bytes)
            } else {
                try backend.delete(service: service, account: account(key))
            }
            return true
        }
    }

    private func read(_ key: String) throws -> StorageEntry? {
        guard let bytes = try backend.read(service: service, account: account(key)) else { return nil }
        guard bytes.count <= 262_144 else { throw StorageFailure.Unavailable }
        let entry = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard entry.revision.count == 43 && entry.payload.utf8.count <= 65_536 else { throw StorageFailure.Unavailable }
        return StorageEntry(revision: entry.revision, payload: entry.payload)
    }

    // ThisDeviceOnly prevents migration to another device, but not restoration
    // of an old backup onto this device. The no-backup installation locator
    // prevents selecting such a journal and reusing a consumed refresh token.
    // Called only inside the namespace's process/file lock.
    private func account(_ key: String) throws -> String {
        let file = directory.appendingPathComponent(key + ".installation")
        let bytes: Data
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue == 36 else { throw StorageFailure.Unavailable }
            bytes = try Data(contentsOf: file)
        } else {
            bytes = Data(UUID().uuidString.utf8)
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            // Persist the locator before creating any usable Keychain record.
            for path in [file.path, directory.path] {
                let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else { throw StorageFailure.Unavailable }
                let result = fsync(fd); Darwin.close(fd)
                guard result == 0 else { throw StorageFailure.Unavailable }
            }
        }
        guard let id = String(data: bytes, encoding: .utf8), UUID(uuidString: id) != nil else {
            throw StorageFailure.Unavailable
        }
        return key + "." + id
    }

    private func transaction<T>(_ key: String, _ action: () throws -> T) throws -> T {
        guard key.range(of: #"^link\.(auth|attest)\.v1\.[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
            throw StorageFailure.Unavailable
        }
        Self.localGate.lock(); defer { Self.localGate.unlock() }
        let descriptor = Darwin.open(directory.appendingPathComponent(key + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StorageFailure.Unavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StorageFailure.Unavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        do { return try action() } catch { throw StorageFailure.Unavailable }
    }
}
