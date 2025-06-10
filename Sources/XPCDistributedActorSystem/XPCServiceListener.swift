import SwiftyXPC

public actor XPCServiceListener {
    enum Error: Swift.Error {
        case previousInstanceExists
    }

    static var shared: XPCServiceListener?

    let actorSystem: XPCDistributedActorSystem
    var lastConnection: XPCConnection? {
        didSet { actorSystem.setConnection(lastConnection) }
    }
    private let listener: XPCListener

    public init(actorSystem: XPCDistributedActorSystem) throws {
        guard Self.shared == nil else { throw Error.previousInstanceExists }
        self.actorSystem = actorSystem
        self.listener = try XPCListener(type: .service, codeSigningRequirement: actorSystem.codeSigningRequirement?.requirement)
        Self.shared = self
        listener.activatedConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            let connection = XPCConnection(incomingConnection: newConnection, actorSystem: actorSystem, codeSigningRequirement: actorSystem.codeSigningRequirement)
            Task { await self.setConnection(connection) }
        }
    }

    public nonisolated func run() -> Never {
        listener.activate()
        dispatchMain()
    }

    func setConnection(_ connection: XPCConnection) async {
        if let lastConnection { await lastConnection.close() }
        self.lastConnection = connection
    }
}
