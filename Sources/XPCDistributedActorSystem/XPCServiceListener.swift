import SwiftyXPC

public actor XPCServiceListener {
    enum Error: Swift.Error {
        case previousInstanceExists
    }

    let actorSystem: XPCDistributedActorSystem
    var lastConnection: SwiftyXPC.XPCConnection?

    private let listener: XPCListener

    public init(listener: XPCListener, actorSystem: XPCDistributedActorSystem) async throws {
        self.actorSystem = actorSystem
        self.listener = listener
        listener.activatedConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            Task {
                await self.setConnection(newConnection)
            }
        }
    }

    public func run() {
        listener.activate()
    }

    func setConnection(_ connection: SwiftyXPC.XPCConnection) async {
        if let lastConnection {
            try? await lastConnection.cancel()
        }
        lastConnection = connection
    }
}
