import SwiftyXPC

actor XPCConnection {
    enum State {
        case created
        case active
        case notFound
        case invalidCodeSigning
    }

    private let connection: SwiftyXPC.XPCConnection
    private let actorSystem: XPCDistributedActorSystem
    private(set) var state: State = .created

    init(incomingConnection: SwiftyXPC.XPCConnection, actorSystem: XPCDistributedActorSystem, codeSigningRequirement: CodeSigningRequirement?) {
        self.connection = incomingConnection
        self.actorSystem = actorSystem
        configureHandlers(requirement: codeSigningRequirement)
        connection.activate()
        state = .active
    }

    init(daemonServiceName: String, actorSystem: XPCDistributedActorSystem, codeSigningRequirement: CodeSigningRequirement?) throws {
        self.connection = try SwiftyXPC.XPCConnection(
            type: .remoteMachService(serviceName: daemonServiceName, isPrivilegedHelperTool: true),
            codeSigningRequirement: codeSigningRequirement?.requirement
        )
        self.actorSystem = actorSystem
        configureHandlers(requirement: codeSigningRequirement)
        try connection.activate()
        state = .active
    }

    init(serviceName: String, actorSystem: XPCDistributedActorSystem, codeSigningRequirement: CodeSigningRequirement?) throws {
        self.connection = try SwiftyXPC.XPCConnection(
            type: .remoteService(bundleID: serviceName),
            codeSigningRequirement: codeSigningRequirement?.requirement
        )
        self.actorSystem = actorSystem
        configureHandlers(requirement: codeSigningRequirement)
        try connection.activate()
        state = .active
    }

    private func configureHandlers(requirement: CodeSigningRequirement?) {
        connection.errorHandler = { [weak self] _, error in
            guard let self else { return }
            if let err = error as? SwiftyXPC.XPCError {
                if err.category == .connectionInvalid {
                    Task { @XPCActor in
                        await self.setState(.notFound)
                        await self.actorSystem.onConnectionInvalidated()
                    }
                }
            }
        }

        connection.setMessageHandler(name: "invoke") { [weak self] _, request in
            guard let self else { return InvocationResponse<Data>(error: "invalid state") }
            return await self.actorSystem.handleInvocation(request: request)
        }
    }

    private func setState(_ state: State) {
        self.state = state
    }

    public func close() {
        connection.cancel()
    }

    func send<ObjectToSend: Codable, ObjectToReceive: Codable>(_ objectToSend: ObjectToSend, expect: ObjectToReceive.Type) async throws -> ObjectToReceive {
        guard state == .active else { throw XPCError(.connectionNotReady) }
        return try await connection.sendMessage(name: "invoke", request: objectToSend)
    }
}
