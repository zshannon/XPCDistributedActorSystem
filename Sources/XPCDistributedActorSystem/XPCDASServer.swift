import Dependencies
import Distributed
import Foundation
import Semaphore
@preconcurrency import SwiftyXPC
import Synchronization

public final class XPCDistributedActorServer: XPCDistributedActorSystem, @unchecked Sendable {
    let liveActorStorage = LiveActorStorage()

    private let actorCreationHandler:
        (@Sendable (XPCDistributedActorServer) async throws -> (any DistributedActor)?)?
    private let actorManager: ActorCreationManager = .init()
    private let codableAsyncStreamManager: CodableAsyncStreamManager<ActorID> = .init()
    private let state: Mutex<XPCDistributedActorSystem.State> = .init(.disconnected)

    @XPCActor private var listener: SwiftyXPC.XPCListener?
    @XPCActor private let activeConnections: Mutex<[UUID: SwiftyXPC.XPCConnection]> = .init([:])
    @XPCActor private let connectionCreatedActors: Mutex<[UUID: [any DistributedActor]]> = .init([:])

    public init(
        listener: SwiftyXPC.XPCListener,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorServer) async throws -> (any DistributedActor)?
        )? = nil
    )
    async throws {
        self.actorCreationHandler = actorCreationHandler
        super.init()
        try await startListening(listener: listener)
    }

    /// Convenience initializer for daemon services
    public init(
        daemonServiceName: String,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorServer) async throws -> (any DistributedActor)?
        )? = nil
    )
    async throws {
        let listener = try SwiftyXPC.XPCListener(
            type: .machService(name: daemonServiceName),
            codeSigningRequirement: codeSigningRequirement?.requirement,
        )
        self.actorCreationHandler = actorCreationHandler
        super.init()
        try await startListening(listener: listener)
    }

    /// Convenience initializer for XPC services
    public init(
        xpcService _: Bool = true,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorServer) async throws -> (any DistributedActor)?
        )? = nil
    )
    async throws {
        let listener = try SwiftyXPC.XPCListener(
            type: .service,
            codeSigningRequirement: codeSigningRequirement?.requirement,
        )
        self.actorCreationHandler = actorCreationHandler
        super.init()
        try await startListening(listener: listener)
    }

    override public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        liveActorStorage.add(actor)
    }

    override public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor, ActorID == Act.ID
    {
        return liveActorStorage.get(id, as: actorType.self)
    }

    override public func assignID<Act>(_: Act.Type) -> ActorID
        where Act: DistributedActor, UUID == Act.ID
    {
        @Dependency(\.nextActorID) var nextActorID
        let id: ActorID = nextActorID ?? .init()
        return id
    }

    override public func resignID(_ id: XPCDistributedActorSystem.ActorID) {
        liveActorStorage.remove(id)
    }

    // called by the XPC connection when an invocation request is received
    func handleInvocation(request: InvocationRequest) async -> InvocationResponse<Data> {
        do {
            var localActor = liveActorStorage.get(request.actorId)

            if localActor == nil, let actorCreationHandler {
                localActor = try await withDependencies {
                    $0.nextActorID = request.actorId
//                    $0.distributedActorSystem = self
                } operation: {
                    try await actorManager.getOrCreateActor(
                        id: request.actorId,
                        system: self,
                        handler: actorCreationHandler,
                    )
                }
                connectionCreatedActors.withLock { connectionIdsToActors in
                    @Dependency(\.connectionID) var connectionID
                    guard let connectionID, let localActor else { return }
                    if connectionIdsToActors[connectionID] == nil {
                        connectionIdsToActors[connectionID] = []
                    }
                    connectionIdsToActors[connectionID]?.append(localActor)
                }
            }

            guard let localActor else {
                throw ProtocolError.failedToFindActorForId(request.actorId)
            }

            var invocationDecoder = InvocationDecoder(system: self, request: request)
            let handler = InvocationResultHandler()

//            let semaphore: AsyncSemaphore = .init(value: 0)
            let handlerResponse = try await withDependencies { _ in
//                $0.dasAsyncStreamCodableSemaphore = semaphore
//                $0.distributedActorSystem = self
            } operation: {
                try await executeDistributedTarget(
                    on: localActor,
                    target: RemoteCallTarget(request.target),
                    invocationDecoder: &invocationDecoder,
                    handler: handler,
                )
                return handler
            }
            if handlerResponse.responseType is _IsAsyncStreamOfCodable.Type {
                // this is a hack to support async decoding of AsyncStream<any Codable>
//                try await semaphore.waitUnlessCancelled()
            }
            return handlerResponse.response ?? InvocationResponse<Data>(error: nil, value: nil)
        } catch {
            return InvocationResponse<Data>(error: error)
        }
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

//    func storeCodableAsyncStream(_ cas: some Identifiable<ActorID> & Sendable) async {
//        await withDependencies { _ in
    ////            $0.distributedActorSystem = self
//        } operation: {
//            await codableAsyncStreamManager.storeCodableAsyncStream(cas)
//        }
//    }
//
//    func releaseCodableAsyncStream(_ id: ActorID) async {
//        await withDependencies { _ in
    ////            $0.distributedActorSystem = self
//        } operation: {
//            await codableAsyncStreamManager.releaseCodableAsyncStream(id)
//        }
//    }
//
    func countCodableAsyncStreams() async -> Int {
//        await withDependencies { _ in
        ////            $0.distributedActorSystem = self
//        } operation: {
//            await codableAsyncStreamManager.countCodableAsyncStreams()
//        }
        0
    }
}

private actor ActorCreationManager {
    private let createSemaphore: AsyncSemaphore = .init(value: 1)

    func getOrCreateActor(
        id: XPCDistributedActorSystem.ActorID,
        system: XPCDistributedActorServer,
        handler: @Sendable (XPCDistributedActorServer) async throws -> (any DistributedActor)?
    )
        async throws -> (any DistributedActor)?
    {
        // Check if already exists
        if let existing = system.liveActorStorage.get(id) {
            return existing
        }

        try await createSemaphore.waitUnlessCancelled()
        defer { createSemaphore.signal() }

        return try await handler(system)
    }
}

private actor CodableAsyncStreamManager<ActorID: Equatable> {
    private var codableAsyncStreams: [any Identifiable<ActorID>] = .init()

    private let casSemaphore: AsyncSemaphore = .init(value: 1)
    private let id: UUID = .init()

    func storeCodableAsyncStream(_ cas: any Identifiable<ActorID>) async {
        await casSemaphore.wait()
        defer { casSemaphore.signal() }
        codableAsyncStreams.append(cas)
    }

    func releaseCodableAsyncStream(_ id: ActorID) async {
        await casSemaphore.wait()
        defer { casSemaphore.signal() }
        codableAsyncStreams.removeAll(where: { $0.id == id })
    }

    func countCodableAsyncStreams() async -> Int {
        await casSemaphore.wait()
        defer { casSemaphore.signal() }
        return codableAsyncStreams.count
    }
}

extension XPCDistributedActorServer {
    private func startListening(listener: SwiftyXPC.XPCListener) async throws {
        await withCheckedContinuation { continuation in
            Task { @XPCActor in
                self.state.withLock { $0 = .connecting }
                self.listener = listener
                await self.setupListener(listener)
                listener.activate()
                self.state.withLock { $0 = .connected }
                continuation.resume()
            }
        }
    }

    @XPCActor public func getActiveConnectionCount() async -> Int {
        activeConnections.withLock {
            $0.count
        }
    }

    @XPCActor private func setupListener(_ listener: SwiftyXPC.XPCListener) async {
        listener.activatedConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            Task { @XPCActor in
                let connectionID: UUID = .init()
                await withDependencies {
                    $0.connectionID = connectionID
                } operation: {
                    await self.handleNewConnection(newConnection)
                }
            }
        }
    }

    @XPCActor private func handleNewConnection(_ connection: SwiftyXPC.XPCConnection) async {
        activeConnections.withLock {
            @Dependency(\.connectionID) var connectionID
            $0[connectionID!] = connection
        }
        await setupConnectionHandlers(connection)

        do {
            try await connection.activate()
        } catch {
            await removeConnection(connection)
        }
    }

    @XPCActor private func setupConnectionHandlers(_ connection: SwiftyXPC.XPCConnection) async {
        withEscapedDependencies { dependencies in
            connection.errorHandler = { [weak self] _, _ in
                guard let self else { return }
                Task { @XPCActor in
                    await dependencies.yield { @Sendable in
                        await self.removeConnection(connection)
                    }
                }
            }
            connection.setMessageHandler(name: "invoke") {
                [weak self] (_: SwiftyXPC.XPCConnection, request: InvocationRequest)
                async throws -> InvocationResponse<Data> in
                guard let self else {
                    return InvocationResponse<Data>(error: "Server unavailable", value: nil)
                }
                return await dependencies.yield { @Sendable in
                    await self.handleInvocation(request: request)
                }
            }
        }
    }

    @XPCActor private func removeConnection(_: SwiftyXPC.XPCConnection) async {
        @Dependency(\.connectionID) var connectionID
        guard let connectionID else { return }
        _ = activeConnections.withLock {
            $0.removeValue(forKey: connectionID)
        }
        _ = connectionCreatedActors.withLock {
            $0.removeValue(forKey: connectionID)
        }
    }
}

public extension DependencyValues {
    var connectionID: XPCDistributedActorSystem.ActorID? {
        get { self[XPCDistributedActorSystem.ActorID.self] }
        set { self[XPCDistributedActorSystem.ActorID.self] = newValue }
    }

    var nextActorID: XPCDistributedActorSystem.ActorID? {
        get { self[XPCDistributedActorSystem.ActorID.self] }
        set { self[XPCDistributedActorSystem.ActorID.self] = newValue }
    }
}

extension XPCDistributedActorSystem.ActorID: @retroactive DependencyKey {
    public static var liveValue: XPCDistributedActorSystem.ActorID? { nil }
    public static var testValue: XPCDistributedActorSystem.ActorID? { nil }
}
