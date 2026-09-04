import Foundation

public protocol TIFTransport: Sendable {
    func notifications() async throws -> AsyncStream<Data>
    func send(_ data: Data) async throws
}