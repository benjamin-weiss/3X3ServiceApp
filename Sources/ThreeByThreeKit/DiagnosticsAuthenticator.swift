import CommonCrypto
import Foundation

public enum DiagnosticsAuthenticationError: Error, Equatable, LocalizedError, Sendable {
    case notificationStreamEnded
    case timedOut
    case unexpectedNotificationLength(Int)
    case unexpectedGrantedLevel(UInt8)
    case encryptionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .notificationStreamEnded:
            "Authentication notifications stopped before the device responded."
        case .timedOut:
            "Timed out waiting for the authentication response."
        case .unexpectedNotificationLength(let length):
            "Received an unexpected \(length)-byte authentication notification."
        case .unexpectedGrantedLevel(let level):
            "The device granted authentication level \(level) instead of level 5."
        case .encryptionFailed(let status):
            "AES challenge encryption failed with status \(status)."
        }
    }
}

public enum DiagnosticsChallengeCipher {
    public static func encrypt(_ challenge: Data) throws -> Data {
        guard challenge.count == kCCBlockSizeAES128 else {
            throw DiagnosticsAuthenticationError.unexpectedNotificationLength(challenge.count)
        }

        let key = Data(stride(from: 0, through: 0xFF, by: 0x11).map(UInt8.init))
        let outputSize = kCCBlockSizeAES128
        var ciphertext = Data(count: outputSize)
        var encryptedLength = 0
        let status = ciphertext.withUnsafeMutableBytes { ciphertextBytes in
            challenge.withUnsafeBytes { challengeBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        challengeBytes.baseAddress,
                        challenge.count,
                        ciphertextBytes.baseAddress,
                        outputSize,
                        &encryptedLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw DiagnosticsAuthenticationError.encryptionFailed(status)
        }
        return ciphertext.prefix(encryptedLength)
    }
}

public enum TRPChallengeCipher {
    public static func encrypt(_ challenge: Data) throws -> Data {
        guard challenge.count == kCCBlockSizeAES128 else {
            throw DiagnosticsAuthenticationError.unexpectedNotificationLength(challenge.count)
        }

        let key = Data(stride(from: 0xFF, through: 0, by: -0x11).map(UInt8.init))
        let outputSize = kCCBlockSizeAES128
        var ciphertext = Data(count: outputSize)
        var encryptedLength = 0
        let status = ciphertext.withUnsafeMutableBytes { ciphertextBytes in
            challenge.withUnsafeBytes { challengeBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        challengeBytes.baseAddress,
                        challenge.count,
                        ciphertextBytes.baseAddress,
                        outputSize,
                        &encryptedLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw DiagnosticsAuthenticationError.encryptionFailed(status)
        }
        return ciphertext.prefix(encryptedLength)
    }
}

@MainActor
public final class DiagnosticsAuthenticator {
    private static let requestedLevel: UInt8 = 5

    private let session: PeripheralSession
    private let trace: @MainActor @Sendable (String) -> Void
    private let timeout: Duration

    public init(
        session: PeripheralSession,
        timeout: Duration = .seconds(10),
        trace: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.session = session
        self.timeout = timeout
        self.trace = trace
    }

    public func authenticate() async throws {
        let uuid = BluetoothUUIDs.DiagnosticsCharacteristic.authentication
        let notifications = try await session.notifications(for: uuid)
        trace("AUTH notifications enabled")

        trace("AUTH level requested: \(Self.requestedLevel)")
        try await session.write(
            Data([0, Self.requestedLevel]),
            to: uuid,
            withResponse: true
        )

        let challenge = try await next(from: notifications)
        guard challenge.count == 16 else {
            throw DiagnosticsAuthenticationError.unexpectedNotificationLength(challenge.count)
        }
        trace("AUTH challenge received: 16 bytes")

        var response = Data([1])
        response.append(try DiagnosticsChallengeCipher.encrypt(challenge))
        try await session.write(response, to: uuid, withResponse: true)
        trace("AUTH challenge response sent")

        let result = try await next(from: notifications)
        guard result.count == 1 else {
            throw DiagnosticsAuthenticationError.unexpectedNotificationLength(result.count)
        }
        guard result[0] == Self.requestedLevel else {
            throw DiagnosticsAuthenticationError.unexpectedGrantedLevel(result[0])
        }
        trace("AUTH level granted: \(result[0])")
    }

    private func next(
        from notifications: AsyncStream<Data>
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for await data in notifications {
                    return data
                }
                throw DiagnosticsAuthenticationError.notificationStreamEnded
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw DiagnosticsAuthenticationError.timedOut
            }

            defer { group.cancelAll() }
            guard let data = try await group.next() else {
                throw DiagnosticsAuthenticationError.notificationStreamEnded
            }
            return data
        }
    }
}

@MainActor
public final class TRPAuthenticator {
    private let session: PeripheralSession
    private let trace: @MainActor @Sendable (String) -> Void

    public init(
        session: PeripheralSession,
        trace: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.session = session
        self.trace = trace
    }

    public func authenticate() async throws {
        let challenge = try await session.read(
            BluetoothUUIDs.AuthenticationCharacteristic.challenge
        )
        trace("TRP AUTH challenge received: \(challenge.count) bytes")
        let response = try TRPChallengeCipher.encrypt(challenge)
        try await session.write(
            response,
            to: BluetoothUUIDs.AuthenticationCharacteristic.responseFD,
            withResponse: true
        )
        trace("TRP AUTH challenge response sent")
    }
}