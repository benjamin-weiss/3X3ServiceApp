import Foundation
@testable import ThreeByThreeKit

actor MockTIFTransport: TIFTransport {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let responses: [Data]
    private(set) var sentData: [Data] = []

    init(responses: [Data] = []) {
        var capturedContinuation: AsyncStream<Data>.Continuation?
        stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
        self.responses = responses
    }

    func notifications() -> AsyncStream<Data> {
        stream
    }

    func send(_ data: Data) {
        sentData.append(data)
        for response in responses {
            continuation.yield(response)
        }
    }
}