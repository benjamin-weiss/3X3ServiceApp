import Foundation

public struct TIFFrame: Equatable, Sendable {
    public static let magic: UInt16 = 0xAFFE
    public static let headerLength = 7

    public let command: UInt8
    public let payload: Data

    public init(command: UInt8, payload: Data = Data()) {
        self.command = command
        self.payload = payload
    }

    public init<C: TIFCommand>(command: C, payload: Data = Data()) {
        self.init(command: command.rawValue, payload: payload)
    }

    public func encoded() throws -> Data {
        guard payload.count <= Int(UInt16.max) else {
            throw TIFFrameError.payloadTooLarge(payload.count)
        }

        var bytes = [UInt8](repeating: 0, count: Self.headerLength + payload.count)
        bytes.writeLittleEndian(Self.magic, at: 0)
        bytes.writeLittleEndian(UInt16(payload.count), at: 2)
        bytes.writeLittleEndian(UInt16.max, at: 4)
        bytes[6] = command
        bytes.replaceSubrange(Self.headerLength..., with: payload)
        bytes.writeLittleEndian(Self.crc16(bytes), at: 4)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> TIFFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength else {
            throw TIFFrameError.frameTooShort(bytes.count)
        }
        guard bytes.readUInt16(at: 0) == magic else {
            throw TIFFrameError.invalidMagic
        }

        let payloadLength = Int(bytes.readUInt16(at: 2))
        guard bytes.count == headerLength + payloadLength else {
            throw TIFFrameError.invalidLength(
                expected: headerLength + payloadLength,
                actual: bytes.count
            )
        }

        let receivedCRC = bytes.readUInt16(at: 4)
        var bytesForCRC = bytes
        bytesForCRC.writeLittleEndian(UInt16.max, at: 4)
        guard crc16(bytesForCRC) == receivedCRC else {
            throw TIFFrameError.invalidChecksum
        }

        return TIFFrame(command: bytes[6], payload: Data(bytes.dropFirst(headerLength)))
    }

    public static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc = UInt16.max
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

public enum TIFFrameError: Error, Equatable, Sendable {
    case frameTooShort(Int)
    case payloadTooLarge(Int)
    case invalidMagic
    case invalidLength(expected: Int, actual: Int)
    case invalidChecksum
}

struct TIFFrameAccumulator {
    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> Data? {
        buffer.append(chunk)
        guard buffer.count >= TIFFrame.headerLength else {
            return nil
        }

        let bytes = [UInt8](buffer.prefix(4))
        guard UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == TIFFrame.magic else {
            throw TIFFrameError.invalidMagic
        }
        let payloadLength = Int(bytes[2]) | Int(bytes[3]) << 8
        let expectedLength = TIFFrame.headerLength + payloadLength
        guard buffer.count <= expectedLength else {
            throw TIFFrameError.invalidLength(
                expected: expectedLength,
                actual: buffer.count
            )
        }
        guard buffer.count == expectedLength else {
            return nil
        }

        let frame = buffer
        buffer.removeAll(keepingCapacity: true)
        return frame
    }
}

private extension Array where Element == UInt8 {
    mutating func writeLittleEndian(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
}