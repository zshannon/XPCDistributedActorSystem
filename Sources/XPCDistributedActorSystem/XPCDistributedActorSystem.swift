import Distributed
import Foundation
@preconcurrency import SwiftyXPC
import Synchronization

// MARK: - Actor Creation Manager

private actor ActorCreationManager {
    private var creatingActors: Set<XPCDistributedActorSystem.ActorID> = []

    func getOrCreateActor(
        id: XPCDistributedActorSystem.ActorID,
        system: XPCDistributedActorSystem,
        handler: @Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?
    )
        async throws -> (any DistributedActor)?
    {
        // Check if already exists
        if let existing = system.liveActorStorage.get(id) {
            return existing
        }

        // Check if already creating
        if creatingActors.contains(id) {
            // Wait a bit and check again
            try await Task.sleep(for: .milliseconds(10))
            return try await getOrCreateActor(id: id, system: system, handler: handler)
        }

        // Mark as creating
        creatingActors.insert(id)
        defer { creatingActors.remove(id) }

        // Double check after marking
        if let existing = system.liveActorStorage.get(id) {
            return existing
        }

        // Create the actor
        let newActor = try await XPCDistributedActorSystem.$pendingActorID.withValue(id) {
            try await handler(system)
        }

        if let actor = newActor {
            system.createdActors.withLock { createdActors in
                createdActors[id] = actor
            }
        }

        return newActor
    }
}

// MARK: - Base System

public class XPCDistributedActorSystem: DistributedActorSystem, @unchecked Sendable {
    public enum State: Sendable {
        case connecting
        case connected
        case disconnected
    }

    enum ProtocolError: Swift.Error, LocalizedError {
        case noConnection
        case failedToFindValueInResponse
        case errorFromRemoteActor(String)
        case failedToFindActorForId(ActorID)

        var errorDescription: String? {
            switch self {
            case .noConnection:
                "No active connection has been found"
            case .failedToFindValueInResponse:
                "Failed to find value in response"
            case let .errorFromRemoteActor(string):
                "Remote: \(string)"
            case let .failedToFindActorForId(actorID):
                "Failed to find actor for ID \(actorID)"
            }
        }
    }

    public typealias ActorID = UUID
    public typealias InvocationEncoder = GenericInvocationEncoder
    public typealias InvocationDecoder = GenericInvocationDecoder
    public typealias ResultHandler = InvocationResultHandler
    public typealias SerializationRequirement = any Codable

    let liveActorStorage = LiveActorStorage()
    let nextActorId: Mutex<[ObjectIdentifier: ActorID]> = .init([:])
    let state: Mutex<State> = .init(.disconnected)
    let actorCreationHandler:
        (@Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?)?

    // Strong references to actors created via handler to keep them alive
    let createdActors: Mutex<[ActorID: any DistributedActor]> = .init([:])

    // Actor to synchronize actor creation to prevent race conditions
    private let actorManager: ActorCreationManager

    // Thread-local storage for overriding the next assigned ID
    @TaskLocal static var pendingActorID: ActorID?

    init(actorCreationHandler: (@Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?)?) {
        self.actorCreationHandler = actorCreationHandler
        actorManager = ActorCreationManager()
    }

    func handleInvocation(request: InvocationRequest) async -> InvocationResponse<Data> {
        do {
            var localActor = liveActorStorage.get(request.actorId)

            if localActor == nil, let actorCreationHandler {
                localActor = try await actorManager.getOrCreateActor(
                    id: request.actorId,
                    system: self,
                    handler: actorCreationHandler,
                )
            }

            guard let localActor else {
                throw ProtocolError.failedToFindActorForId(request.actorId)
            }

            var invocationDecoder = InvocationDecoder(system: self, request: request)
            let handler = InvocationResultHandler()

            try await executeDistributedTarget(
                on: localActor,
                target: RemoteCallTarget(request.target),
                invocationDecoder: &invocationDecoder,
                handler: handler,
            )

            return handler.response ?? InvocationResponse<Data>(error: nil, value: nil)
        } catch {
            return InvocationResponse<Data>(error: error)
        }
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        InvocationEncoder()
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        liveActorStorage.add(actor)
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor, ActorID == Act.ID
    {
        liveActorStorage.get(id, as: actorType.self)
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
        where Act: DistributedActor, UUID == Act.ID
    {
        // Check if there's a pending actor ID to use (for actor creation handler)
        if let pendingID = XPCDistributedActorSystem.pendingActorID {
            return pendingID
        }

        var id: Act.ID?

        nextActorId.withLock { dictionary in
            let nextId: Act.ID = .init()
            dictionary[ObjectIdentifier(actorType)] = nextId
            id = nextId
        }

        guard let id else {
            fatalError("Failed to assign ID")
        }

        return id
    }

    public func resignID(_ id: XPCDistributedActorSystem.ActorID) {
        liveActorStorage.remove(id)
        // Also remove from strong reference storage
        _ = createdActors.withLock { createdActors in
            createdActors.removeValue(forKey: id)
        }
    }

    // Abstract methods to be implemented by subclasses
    public func remoteCall<Act, Res>(
        on _: Act, target _: RemoteCallTarget, invocation _: inout InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Res: Codable
    {
        fatalError("Must be implemented by subclass")
    }

    public func remoteCallVoid<Act>(
        on _: Act, target _: RemoteCallTarget, invocation _: inout InvocationEncoder,
        throwing _: (some Error).Type
    )
        async throws where Act: DistributedActor, Act.ID == ActorID
    {
        fatalError("Must be implemented by subclass")
    }

    // For backwards compatibility with XPCServiceListener
    nonisolated func setConnection(_: SwiftyXPC.XPCConnection?) {
        // This method was used by XPCServiceListener but is no longer needed
        // in the new architecture since clients and servers handle connections internally
    }
}

// MARK: - Client System

public final class XPCDistributedActorClient: XPCDistributedActorSystem {
    public enum ConnectionType: Sendable {
        case daemon(serviceName: String)
        case xpcService(serviceName: String)
        case endpoint(SwiftyXPC.XPCEndpoint)
    }

    @XPCActor private var xpcConnection: SwiftyXPC.XPCConnection?
    private let connectionType: ConnectionType
    private let codeSigningRequirement: CodeSigningRequirement?

    public init(
        connectionType: ConnectionType,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (@Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?)? = nil
    )
    async throws {
        self.codeSigningRequirement = codeSigningRequirement
        self.connectionType = connectionType
        super.init(actorCreationHandler: actorCreationHandler)
        try await connect()
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            Task { @XPCActor in
                do {
                    self.state.withLock { $0 = .connecting }
                    let connection = try self.createConnection()
                    self.xpcConnection = connection
                    self.setupConnectionHandlers(connection)
                    try await connection.activate()
                    self.state.withLock { $0 = .connected }
                    continuation.resume()
                } catch {
                    self.state.withLock { $0 = .disconnected }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @XPCActor private func createConnection() throws -> SwiftyXPC.XPCConnection {
        switch connectionType {
        case let .daemon(serviceName):
            try SwiftyXPC.XPCConnection(
                type: .remoteMachService(serviceName: serviceName, isPrivilegedHelperTool: true),
                codeSigningRequirement: codeSigningRequirement?.requirement,
            )
        case let .xpcService(serviceName):
            try SwiftyXPC.XPCConnection(
                type: .remoteService(bundleID: serviceName),
                codeSigningRequirement: codeSigningRequirement?.requirement,
            )
        case let .endpoint(endpoint):
            try SwiftyXPC.XPCConnection(
                type: .remoteServiceFromEndpoint(endpoint),
                codeSigningRequirement: codeSigningRequirement?.requirement,
            )
        }
    }

    @XPCActor private func setupConnectionHandlers(_ connection: SwiftyXPC.XPCConnection) {
        connection.errorHandler = { [weak self] _, _ in
            guard let self else { return }
            Task { @XPCActor in
                self.onConnectionInvalidated()
            }
        }
    }

    @XPCActor private func onConnectionInvalidated() {
        state.withLock { $0 = .disconnected }
        // Automatically reconnect for client connections
        Task {
            try? await connect()
        }
    }

    override public func remoteCall<Act, Res>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Res: Codable
    {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }

        let request = InvocationRequest(
            actorId: actor.id, target: target.identifier, invocation: invocation,
        )
        let response: InvocationResponse<Data> = try await xpcConnection.sendMessage(
            name: "invoke", request: request,
        )

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }

        guard let valueData = response.value else {
            throw ProtocolError.failedToFindValueInResponse
        }

        return try JSONDecoder().decode(Res.self, from: valueData)
    }

    override public func remoteCallVoid<Act>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing _: (some Error).Type
    )
        async throws where Act: DistributedActor, Act.ID == ActorID
    {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }

        let request = InvocationRequest(
            actorId: actor.id, target: target.identifier, invocation: invocation,
        )
        let response: InvocationResponse<Data> = try await xpcConnection.sendMessage(
            name: "invoke", request: request,
        )

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }
    }
}

// MARK: - Server System

public final class XPCDistributedActorServer: XPCDistributedActorSystem {
    @XPCActor private var listener: SwiftyXPC.XPCListener?
    @XPCActor private var activeConnections: [SwiftyXPC.XPCConnection] = []

    public init(
        listener: SwiftyXPC.XPCListener,
        actorCreationHandler: (@Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?)? = nil
    )
    async throws {
        super.init(actorCreationHandler: actorCreationHandler)
        try await startListening(listener: listener)
    }

    /// Convenience initializer for daemon services
    public init(
        daemonServiceName: String,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (@Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?)? = nil
    )
    async throws {
        let listener = try SwiftyXPC.XPCListener(
            type: .machService(name: daemonServiceName),
            codeSigningRequirement: codeSigningRequirement?.requirement,
        )
        super.init(actorCreationHandler: actorCreationHandler)
        try await startListening(listener: listener)
    }

    /// Convenience initializer for XPC services
    public init(
        xpcService _: Bool = true,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (@Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?)? = nil
    )
    async throws {
        let listener = try SwiftyXPC.XPCListener(
            type: .service,
            codeSigningRequirement: codeSigningRequirement?.requirement,
        )
        super.init(actorCreationHandler: actorCreationHandler)
        try await startListening(listener: listener)
    }

    private func startListening(listener: SwiftyXPC.XPCListener) async throws {
        await withCheckedContinuation { continuation in
            Task { @XPCActor in
                self.state.withLock { $0 = .connecting }
                self.listener = listener
                self.setupListener(listener)
                listener.activate()
                self.state.withLock { $0 = .connected }
                continuation.resume()
            }
        }
    }

    @XPCActor private func setupListener(_ listener: SwiftyXPC.XPCListener) {
        listener.activatedConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            Task { @XPCActor in
                self.handleNewConnection(newConnection)
            }
        }
    }

    @XPCActor private func handleNewConnection(_ connection: SwiftyXPC.XPCConnection) {
        activeConnections.append(connection)
        setupConnectionHandlers(connection)

        Task {
            do {
                try await connection.activate()
            } catch {
                self.removeConnection(connection)
            }
        }
    }

    @XPCActor private func setupConnectionHandlers(_ connection: SwiftyXPC.XPCConnection) {
        connection.errorHandler = { [weak self] _, _ in
            guard let self else { return }
            Task { @XPCActor in
                self.removeConnection(connection)
            }
        }

        connection.setMessageHandler(name: "invoke") {
            [weak self] (_: SwiftyXPC.XPCConnection, request: InvocationRequest)
            async throws -> InvocationResponse<Data> in
            guard let self else {
                return InvocationResponse<Data>(error: "Server unavailable", value: nil)
            }
            return await self.handleInvocation(request: request)
        }
    }

    @XPCActor private func removeConnection(_ connection: SwiftyXPC.XPCConnection) {
        activeConnections.removeAll { $0 === connection }
    }

    override public func remoteCall<Act, Res>(
        on _: Act, target _: RemoteCallTarget, invocation _: inout InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Res: Codable
    {
        // Server systems typically don't make remote calls, but if needed, this could be implemented
        // to call out to other services
        throw ProtocolError.noConnection
    }

    override public func remoteCallVoid<Act>(
        on _: Act, target _: RemoteCallTarget, invocation _: inout InvocationEncoder,
        throwing _: (some Error).Type
    )
        async throws where Act: DistributedActor, Act.ID == ActorID
    {
        // Server systems typically don't make remote calls, but if needed, this could be implemented
        // to call out to other services
        throw ProtocolError.noConnection
    }

    @XPCActor public func getActiveConnectionCount() -> Int {
        activeConnections.count
    }
}
