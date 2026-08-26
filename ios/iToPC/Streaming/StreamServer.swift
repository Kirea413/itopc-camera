import Foundation
import Network

final class StreamServer {
    var onConnectionChanged: ((Bool) -> Void)?
    var onNeedsKeyFrame: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "local.itopc.network", qos: .userInteractive)
    private let port: NWEndpoint.Port = 5000
    private var listener: NWListener?
    private var connection: NWConnection?
    private var pendingFrames: [(data: Data, keyFrame: Bool)] = []
    private var isSending = false
    private var droppingUntilKeyFrame = true
    private var connectionGeneration = UUID()

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.connection?.cancel()
            self.listener = nil
            self.connection = nil
            self.pendingFrames.removeAll(keepingCapacity: false)
            self.isSending = false
            self.droppingUntilKeyFrame = true
            self.publishConnection(false)
        }
    }

    func send(_ data: Data, isKeyFrame: Bool) {
        queue.async { [weak self] in
            guard let self, self.connection != nil else { return }

            if self.droppingUntilKeyFrame {
                guard isKeyFrame else { return }
                self.droppingUntilKeyFrame = false
            }

            if self.pendingFrames.count >= 3 {
                self.pendingFrames.removeAll(keepingCapacity: true)
                self.droppingUntilKeyFrame = true
                self.onNeedsKeyFrame?()
                guard isKeyFrame else { return }
                self.droppingUntilKeyFrame = false
            }

            self.pendingFrames.append((data, isKeyFrame))
            self.pumpLocked()
        }
    }

    private func startLocked() {
        guard listener == nil else { return }
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 2
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.allowLocalEndpointReuse = true

            let newListener = try NWListener(using: parameters, on: port)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.acceptLocked(connection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.publishError(error)
                }
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            publishError(error)
        }
    }

    private func acceptLocked(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection
        pendingFrames.removeAll(keepingCapacity: true)
        isSending = false
        droppingUntilKeyFrame = true
        let generation = UUID()
        connectionGeneration = generation

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, generation == self.connectionGeneration else { return }
            switch state {
            case .ready:
                self.publishConnection(true)
                self.onNeedsKeyFrame?()
            case .failed(let error):
                self.publishError(error)
                self.closeLocked(newConnection, generation: generation)
            case .cancelled:
                self.closeLocked(newConnection, generation: generation)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func pumpLocked() {
        guard
            !isSending,
            !pendingFrames.isEmpty,
            let activeConnection = connection
        else { return }

        isSending = true
        let frame = pendingFrames.removeFirst()
        let generation = connectionGeneration
        activeConnection.send(content: frame.data, completion: .contentProcessed { [weak self] error in
            guard let self, generation == self.connectionGeneration else { return }
            self.isSending = false
            if let error {
                self.publishError(error)
                self.closeLocked(activeConnection, generation: generation)
                return
            }
            self.pumpLocked()
        })
    }

    private func closeLocked(_ target: NWConnection?, generation: UUID) {
        guard generation == connectionGeneration else { return }
        target?.cancel()
        connection = nil
        pendingFrames.removeAll(keepingCapacity: true)
        isSending = false
        droppingUntilKeyFrame = true
        publishConnection(false)
    }

    private func publishConnection(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onConnectionChanged?(connected) }
    }

    private func publishError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}

