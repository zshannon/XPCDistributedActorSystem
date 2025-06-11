import SwiftyXPC

public actor XPCDaemonListener {
    let actorSystem: XPCDistributedActorSystem
    var lastConnection: SwiftyXPC.XPCConnection?
    private let listener: XPCListener

    public init(
        daemonServiceName: String,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorSystem: XPCDistributedActorSystem
    )
    async throws {
        self.actorSystem = actorSystem
        listener = try XPCListener(
            type: .machService(name: daemonServiceName),
            codeSigningRequirement: codeSigningRequirement?.requirement,
        )
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
        lastConnection = connection
    }
}
