import SwiftyXPC

public actor XPCDaemonListener {
    let actorSystem: XPCDistributedActorSystem
    var lastConnection: SwiftyXPC.XPCConnection?
    private let listener: XPCListener

    public init(daemonServiceName: String, actorSystem: XPCDistributedActorSystem) async throws {
        self.actorSystem = actorSystem
        self.listener = try XPCListener(type: .machService(name: daemonServiceName), codeSigningRequirement: actorSystem.codeSigningRequirement?.requirement)
        listener.activatedConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            Task {
                await self.setConnection(newConnection)
            }
        }
        listener.activate()
    }

    func setConnection(_ connection: SwiftyXPC.XPCConnection) async {
        if let lastConnection {
            try? await lastConnection.cancel()
        }
        self.lastConnection = connection
    }
}
