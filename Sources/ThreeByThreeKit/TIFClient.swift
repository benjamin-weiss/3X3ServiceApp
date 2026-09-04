import Foundation

public actor TIFClient {
    private let transport: any TIFTransport
    private let timeout: Duration
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        transport: any TIFTransport,
        timeout: Duration = .seconds(5)
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func send<C: TIFCommand>(
        _ command: C,
        payload: Data = Data()
    ) async throws {
        await acquireOperation()
        do {
            let frame = try TIFFrame(command: command, payload: payload).encoded()
            try await transport.send(frame)
            releaseOperation()
        } catch {
            releaseOperation()
            throw error
        }
    }

    public func request<C: TIFCommand>(
        _ command: C,
        payload: Data = Data()
    ) async throws -> TIFFrame {
        await acquireOperation()
        do {
            let response = try await performRequest(command, payload: payload)
            releaseOperation()
            return response
        } catch {
            releaseOperation()
            throw error
        }
    }

    private func performRequest<C: TIFCommand>(
        _ command: C,
        payload: Data
    ) async throws -> TIFFrame {
        let notifications = try await transport.notifications()
        let request = try TIFFrame(command: command, payload: payload).encoded()
        try await transport.send(request)

        return try await withThrowingTaskGroup(of: TIFFrame.self) { group in
            group.addTask {
                for await data in notifications {
                    guard let frame = try? TIFFrame.decode(data) else {
                        continue
                    }
                    if frame.command == 0xFF {
                        throw TIFClientError.device(frame.payload)
                    }
                    if frame.command == command.rawValue | 0x80 {
                        return frame
                    }
                }
                throw TIFClientError.notificationStreamEnded
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw TIFClientError.timedOut(command: command.rawValue)
            }

            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw TIFClientError.notificationStreamEnded
            }
            return response
        }
    }

    private func acquireOperation() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

public enum TIFClientError: Error, Equatable, Sendable {
    case device(Data)
    case notificationStreamEnded
    case timedOut(command: UInt8)
}