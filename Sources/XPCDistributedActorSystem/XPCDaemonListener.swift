import SwiftyXPC

public actor XPCDaemonListener {
    let actorSystem: XPCDistributedActorSystem
    var lastConnection: XPCConnection?
    private let listener: XPCListener

    public init(daemonServiceName: String, actorSystem: XPCDistributedActorSystem) throws {
        self.actorSystem = actorSystem
        self.listener = try XPCListener(type: .machService(name: daemonServiceName), codeSigningRequirement: actorSystem.codeSigningRequirement?.requirement)
        listener.activatedConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            let connection = XPCConnection(incomingConnection: newConnection, actorSystem: actorSystem, codeSigningRequirement: actorSystem.codeSigningRequirement)
            Task { await self.setConnection(connection) }
        }
        listener.activate()
    }

    func setConnection(_ connection: XPCConnection) async {
        if let lastConnection {
            await lastConnection.close()
        }
        self.lastConnection = connection
    }
}
