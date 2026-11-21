import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif
#if canImport(LinkAuthCore)
import LinkAuthCore
#endif

/// Apple App Attest, iOS 14+. The key lives in the Secure Enclave and is bound
/// to the server's challenge by `attestKey`; every token request is then signed
/// with `generateAssertion`, which needs no network. The key is attested once,
/// at the first sign-in, never at app launch: Apple limits how often `attestKey`
/// may be called. iOS 13, the simulator, app extensions, a missing App Attest
/// capability and unreachable Apple servers all mean "no key": the sign-in goes
/// on and the server decides.
final class AppAttestAttestor: DeviceAttestor, @unchecked Sendable {
    func isAvailable() -> Bool {
        #if targetEnvironment(simulator) || !canImport(DeviceCheck)
        return false
        #else
        if #available(iOS 14.0, macOS 11.0, *) { return DCAppAttestService.shared.isSupported }
        return false
        #endif
    }

    func createKey(name: String, challenge: Data, timeoutMillis: UInt32) async throws -> AttestedKey {
        #if canImport(DeviceCheck)
        guard challenge.count == 32, isAvailable(), #available(iOS 14.0, macOS 11.0, *) else {
            throw AttestationFailure.Unavailable
        }
        return try await Self.withDeadline(timeoutMillis) {
            let service = DCAppAttestService.shared
            let keyId = try await service.generateKey()
            let attestation = try await service.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: challenge)))
            // keyId is sent to the server exactly as the system returned it.
            return AttestedKey(keyRef: keyId, attestation: .apple(keyId: keyId, attestation: attestation))
        }
        #else
        throw AttestationFailure.Unavailable
        #endif
    }

    func sign(keyRef: String, message: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        guard isAvailable(), #available(iOS 14.0, macOS 11.0, *) else { throw AttestationFailure.Unavailable }
        do {
            return try await DCAppAttestService.shared.generateAssertion(keyRef,
                clientDataHash: Data(SHA256.hash(data: message)))
        } catch let error as DCError where error.code == .invalidKey {
            // The system no longer knows this key: reinstall or device migration.
            throw AttestationFailure.KeyLost
        } catch {
            throw AttestationFailure.Unavailable
        }
        #else
        throw AttestationFailure.Unavailable
        #endif
    }

    /// An app cannot delete an App Attest key; a forgotten key is never used again.
    func deleteKey(keyRef: String) async throws {}

    /// The system calls do not observe task cancellation, so the deadline is
    /// enforced here and a late result is dropped.
    private static func withDeadline<T: Sendable>(_ milliseconds: UInt32,
        _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let settled = Settled()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do {
                    let value = try await operation()
                    if settled.claim() { continuation.resume(returning: value) }
                } catch {
                    if settled.claim() { continuation.resume(throwing: AttestationFailure.Unavailable) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                if settled.claim() {
                    work.cancel()
                    continuation.resume(throwing: AttestationFailure.Unavailable)
                }
            }
        }
    }

    private final class Settled: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
