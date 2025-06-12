import Dependencies
import Distributed
import Foundation

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
    public typealias SerializationRequirement = Codable

    var isServer: Bool { true }

    public func actorReady<Act>(_: Act) where Act: DistributedActor, ActorID == Act.ID {
        fatalError("subclass must override")
    }

    public func assignID<Act>(_: Act.Type) -> ActorID
        where Act: DistributedActor, ActorID == Act.ID
    {
        fatalError("subclass must override")
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            InvocationEncoder(actorSystem: self)
        }
    }

    public func resignID(_: XPCDistributedActorSystem.ActorID) {
        fatalError("subclass must override")
    }

    public func resolve<Act>(id _: ActorID, as _: Act.Type) throws -> Act?
        where Act: DistributedActor, ActorID == Act.ID
    {
        fatalError("subclass must override")
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

    // swiftformat:disable:next opaqueGenericParameters,unusedArguments
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: SerializationRequirement
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

    func storeCodableAsyncStream(_ cas: some Identifiable<ActorID> & Sendable) async {
        await withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            await codableAsyncStreamManager.storeCodableAsyncStream(cas)
        }
    }

    func releaseCodableAsyncStream(_ id: ActorID) async {
        await withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            await codableAsyncStreamManager.releaseCodableAsyncStream(id)
        }
    }

    func countCodableAsyncStreams() async -> Int {
        await withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            await codableAsyncStreamManager.countCodableAsyncStreams()
        }
    }
}

// MARK: - Client System

public final class XPCDistributedActorClient: XPCDistributedActorSystem, @unchecked Sendable {
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
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?
        )? = nil
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

        connection.setMessageHandler(name: "invoke") {
            [weak self] (connection: SwiftyXPC.XPCConnection, request: InvocationRequest)
            async throws -> InvocationResponse<Data> in
            guard let self else {
                return InvocationResponse<Data>(error: "Server unavailable", value: nil)
            }
            return await withDependencies {
                $0.connection = connection
                $0.distributedActorSystem = self
            } operation: {
                await self.handleInvocation(request: request)
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

        let response: InvocationResponse<Data> = try await withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            let request = InvocationRequest(
                actorId: actor.id, target: target.identifier, invocation: invocation,
            )
            return try await xpcConnection.sendMessage(
                name: "invoke", request: request,
            )
        }

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }

        guard let valueData = response.value else {
            throw ProtocolError.failedToFindValueInResponse
        }

        let semaphore: AsyncSemaphore = .init(value: 0)
        return try await withDependencies {
            $0.dasAsyncStreamCodableSemaphore = semaphore
            $0.distributedActorSystem = self
        } operation: {
            let result = try JSONDecoder().decode(Res.self, from: valueData)
            if Res.self is _IsAsyncStreamOfCodable.Type {
                // this is a hack to support async decoding of AsyncStream<any Codable>
                try await semaphore.waitUnlessCancelled()
            }
            return result
        }
    }

    override public func remoteCallVoid<Act>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing _: (some Error).Type
    )
        async throws where Act: DistributedActor, Act.ID == ActorID
    {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }

        let response: InvocationResponse<Data> = try await withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            let request = InvocationRequest(
                actorId: actor.id, target: target.identifier, invocation: invocation,
            )
            return try await xpcConnection.sendMessage(
                name: "invoke", request: request,
            )
        }

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }
    }
}

// MARK: - Server System

public final class XPCDistributedActorServer: XPCDistributedActorSystem, @unchecked Sendable {
    @XPCActor private var listener: SwiftyXPC.XPCListener?
    @XPCActor private var activeConnections: [SwiftyXPC.XPCConnection] = []

    public init(
        listener: SwiftyXPC.XPCListener,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?
        )? = nil
    )
    async throws {
        super.init(actorCreationHandler: actorCreationHandler)
        try await startListening(listener: listener)
    }

    /// Convenience initializer for daemon services
    public init(
        daemonServiceName: String,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?
        )? = nil
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
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?
        )? = nil
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
            [weak self] (connection: SwiftyXPC.XPCConnection, request: InvocationRequest)
            async throws -> InvocationResponse<Data> in
            guard let self else {
                return InvocationResponse<Data>(error: "Server unavailable", value: nil)
            }
            return await withDependencies {
                $0.connection = connection
                $0.distributedActorSystem = self
            } operation: {
                await self.handleInvocation(request: request)
            }
        }
    }

    @XPCActor private func removeConnection(_ connection: SwiftyXPC.XPCConnection) {
        activeConnections.removeAll { $0 === connection }
    }

    override public func remoteCall<Act, Res>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Res: Codable
    {
        @Dependency(\.connection) var xpcConnection
        guard let xpcConnection else { throw ProtocolError.noConnection }

        let response: InvocationResponse<Data> = try await withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            let request = InvocationRequest(
                actorId: actor.id, target: target.identifier, invocation: invocation,
            )
            return try await xpcConnection.sendMessage(
                name: "invoke", request: request,
            )
        }

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }

        guard let valueData = response.value else {
            throw ProtocolError.failedToFindValueInResponse
        }

        let semaphore: AsyncSemaphore = .init(value: 0)
        return try await withDependencies {
            $0.dasAsyncStreamCodableSemaphore = semaphore
            $0.distributedActorSystem = self
        } operation: {
            let result = try JSONDecoder().decode(Res.self, from: valueData)
            if Res.self is _IsAsyncStreamOfCodable.Type {
                // this is a hack to support async decoding of AsyncStream<any Codable>
                try await semaphore.waitUnlessCancelled()
            }
            return result
        }
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

extension XPCDistributedActorSystem: DependencyKey {
    public static var liveValue: XPCDistributedActorSystem? {
        nil
    }
}

extension XPCDistributedActorSystem: TestDependencyKey {
    public static var testValue: XPCDistributedActorSystem? {
//        print(Thread.callStackSymbols.joined(separator: "\n"))
//        fatalError("XPCDistributedActorSystem must be provided via withDependencies")
//        return .init(actorCreationHandler: { _ in nil })
        nil
    }
}

extension AsyncSemaphore: @retroactive DependencyKey {
    public static var liveValue: AsyncSemaphore {
        print(Thread.callStackSymbols.joined(separator: "\n"))
        fatalError("XPCDistributedActorSystem must be provided via withDependencies")
    }
}

extension AsyncSemaphore: @retroactive TestDependencyKey {
    public static var testValue: AsyncSemaphore {
//        print(Thread.callStackSymbols.joined(separator: "\n"))
//        fatalError("XPCDistributedActorSystem must be provided via withDependencies")
        .init(value: 1)
    }
}

extension SwiftyXPC.XPCConnection: @retroactive DependencyKey {
    public static var liveValue: XPCConnection? { nil }
    public static var testValue: XPCConnection? { nil }
}

extension DependencyValues {
    var connection: SwiftyXPC.XPCConnection? {
        get { self[SwiftyXPC.XPCConnection.self] }
        set { self[SwiftyXPC.XPCConnection.self] = newValue }
    }

    var dasAsyncStreamCodableSemaphore: AsyncSemaphore {
        get { self[AsyncSemaphore.self] }
        set { self[AsyncSemaphore.self] = newValue }
    }

    var distributedActorSystem: XPCDistributedActorSystem? {
        get { self[XPCDistributedActorSystem.self] }
        set { self[XPCDistributedActorSystem.self] = newValue }
    }
}

private actor ActorCreationManager {
    private let createSemaphore: AsyncSemaphore = .init(value: 1)

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

        try await createSemaphore.waitUnlessCancelled()
        defer { createSemaphore.signal() }

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
