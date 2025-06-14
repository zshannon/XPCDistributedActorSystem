import Dependencies
import Distributed
import Foundation
import Queue
import Semaphore
@preconcurrency import SwiftyXPC
import Synchronization

public struct TypedUUID: Codable, Hashable, Sendable {
    let type: String
    let uuid: String

    init(_ type: (some Any).Type) {
        self.type = String(reflecting: type)
        uuid = UUID().uuidString
    }

    func matchesType(_ type: some Any) -> Bool {
        return String(reflecting: type) == self.type
    }
}

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
        case failedToCreateActorForId(ActorID)
        case failedToFindActorForId(ActorID)

        var errorDescription: String? {
            switch self {
            case .noConnection:
                "No active connection has been found"
            case .failedToFindValueInResponse:
                "Failed to find value in response"
            case let .errorFromRemoteActor(string):
                "Remote: \(string)"
            case let .failedToCreateActorForId(actorID):
                "Failed to create actor for ID \(actorID)"
            case let .failedToFindActorForId(actorID):
                "Failed to find actor for ID \(actorID)"
            }
        }
    }

    public typealias ActorRequirement = DistributedActor
    public typealias ActorID = TypedUUID
    public typealias InvocationEncoder = GenericInvocationEncoder
    public typealias InvocationDecoder = GenericInvocationDecoder
    public typealias ResultHandler = InvocationResultHandler
    public typealias SerializationRequirement = Codable

    let liveActorStorage = LiveActorStorage()
    let state: Mutex<State> = .init(.disconnected)
    let actorCreationHandler:
        (@Sendable (XPCDistributedActorSystem) async throws -> (any ActorRequirement)?)?

    // Strong references to actors created via handler to keep them alive
    let createdActors: Mutex<[ActorID: any ActorRequirement]> = .init([:])

    private let onConnectionCloseCallbacks: Mutex<[SwiftyXPC.XPCConnection: [@Sendable () async -> Void]]> = .init([:])

    // Thread-local storage for overriding the next assigned ID
    @TaskLocal static var pendingActorID: ActorID?

    init(
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any ActorRequirement)?
        )?
    ) {
        self.actorCreationHandler = actorCreationHandler
    }

    let invocations: Mutex<[(UUID, AsyncSemaphore)]> = .init([])
    func handleInvocation(request: InvocationRequest) async -> InvocationResponse<Data> {
        let requestId = UUID()
        let cancellationSemaphore: AsyncSemaphore = .init(value: 0)
        invocations.withLock { $0 += [(requestId, cancellationSemaphore)] }
        defer {
            invocations.withLock { $0.removeAll(where: { $0.0 == requestId }) }
        }
        do {
            var localActor = liveActorStorage.get(request.actorId)

            if localActor == nil, let actorCreationHandler {
                localActor = try await withDependencies {
                    $0.distributedActorSystem = self
                } operation: {
                    try await getOrCreateActor(
                        id: request.actorId,
                        handler: actorCreationHandler,
                    )
                }
            }

            guard let localActor else {
                throw ProtocolError.failedToFindActorForId(request.actorId)
            }

            let t = Task {
                let handler = InvocationResultHandler()

                let semaphore: AsyncSemaphore = .init(value: 0)
                let handlerResponse = try await withDependencies {
                    $0.dasAsyncStreamCodableSemaphore = semaphore
                    $0.distributedActorSystem = self
                } operation: {
                    var invocationDecoder = InvocationDecoder(system: self, request: request)
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
                    try await semaphore.waitUnlessCancelled()
                }
                return handlerResponse.response ?? InvocationResponse<Data>(error: nil, value: nil)
            }
            Task.detached {
                try await cancellationSemaphore.waitUnlessCancelled()
                t.cancel()
            }
            return try await t.value
        } catch {
            return InvocationResponse<Data>(error: error)
        }
    }

    private func getOrCreateActor(
        id: XPCDistributedActorSystem.ActorID,
        handler: @Sendable (XPCDistributedActorSystem) async throws -> (any ActorRequirement)?
    )
        async throws -> (any ActorRequirement)?
    {
        // Check if already exists
        if let existing = liveActorStorage.get(id) {
            return existing
        }

        // Create the actor
        let newActor = try await XPCDistributedActorSystem.$pendingActorID.withValue(id) {
            try await handler(self)
        }

        if let actor = newActor {
            guard id.matchesType(actor.self) else {
                _ = liveActorStorage.remove(id)
                throw ProtocolError.failedToCreateActorForId(id)
            }
            createdActors.withLock { createdActors in
                createdActors[id] = actor
            }
            await onConnectionClose { [weak self] in
                guard let self else { return }
                createdActors.withLock { createdActors in
                    _ = createdActors.removeValue(forKey: id)
                }
            }
        }

        return newActor
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            InvocationEncoder(actorSystem: self)
        }
    }

    public func actorReady<Act>(_ actor: Act) where Act: ActorRequirement, ActorID == Act.ID {
        liveActorStorage.add(actor)
        Task {
            await onConnectionClose { [weak self, actor] in
                guard let self else { return }
                _ = liveActorStorage.remove(actor.id)
                createdActors.withLock { createdActors in
                    _ = createdActors.removeValue(forKey: actor.id)
                }
            }
        }
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: ActorRequirement, ActorID == Act.ID
    {
        return liveActorStorage.get(id, as: actorType.self)
    }

    public func assignID<Act>(_ type: Act.Type) -> ActorID
        where Act: ActorRequirement, ActorID == Act.ID
    {
        // Check if there's a pending actor ID to use (for actor creation handler)
        if let pendingID = XPCDistributedActorSystem.pendingActorID {
            return pendingID
        }

        return .init(type)
    }

    public func resignID(_ id: XPCDistributedActorSystem.ActorID) {
        _ = liveActorStorage.remove(id)
        createdActors.withLock {
            _ = $0.removeValue(forKey: id)
        }
    }

    // Abstract methods to be implemented by subclasses
    public func remoteCall<Act, Res>(
        on _: Act, target _: RemoteCallTarget, invocation _: inout InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: ActorRequirement, Act.ID == ActorID, Res: Codable
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
        where Act: ActorRequirement, Act.ID == ActorID, Err: Error, Res: SerializationRequirement
    {
        fatalError("Must be implemented by subclass")
    }

    public func remoteCallVoid<Act>(
        on _: Act, target _: RemoteCallTarget, invocation _: inout InvocationEncoder,
        throwing _: (some Error).Type
    )
        async throws where Act: ActorRequirement, Act.ID == ActorID
    {
        fatalError("Must be implemented by subclass")
    }

    func onConnectionClose(
        connection: SwiftyXPC.XPCConnection? = nil,
        _ callback: @escaping @Sendable () async -> Void,
    ) async {
        var connection = connection
        if connection == nil {
            @Dependency(\.connection) var c
            connection = c
        }
        assert(connection != nil, "No connection available to monitor for close")
        guard let connection else { return }
        onConnectionCloseCallbacks.withLock { onConnectionCloseCallbacks in
            onConnectionCloseCallbacks[connection] = onConnectionCloseCallbacks[connection, default: []] + [callback]
        }
    }

    func connectionClose(connection: SwiftyXPC.XPCConnection) async {
        await withTaskGroup { group in
            onConnectionCloseCallbacks.withLock { onConnectionCloseCallbacks in
                for callback in onConnectionCloseCallbacks[connection, default: []] {
                    group.addTask {
                        await callback()
                    }
                }
            }
            await group.waitForAll()
        }
//        let queue = connectionQueue(for: connection)
//        queue.cancelAllPendingTasks()
    }

    func onConnectionQueue<T: Sendable>(
        _ connection: SwiftyXPC.XPCConnection,
        barrier _: Bool = false,
        _ execute: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let queue = connectionQueue(for: connection)
        return try await queue.addOperation {
            try await withDependencies {
                $0.connection = connection
            } operation: {
                try await execute()
            }
        }.value
    }

    func onConnectionQueue<T: Sendable>(
        _ connection: SwiftyXPC.XPCConnection,
        barrier _: Bool = false,
        _ execute: @escaping @Sendable () async -> T
    ) async throws -> T {
        let queue = connectionQueue(for: connection)
        return await queue.addOperation {
            await withDependencies {
                $0.connection = connection
            } operation: {
                await execute()
            }
        }.value
    }

    let connectionQueues: Mutex<[SwiftyXPC.XPCConnection: AsyncQueue]> = .init([:])
    func connectionQueue(for connection: SwiftyXPC.XPCConnection) -> AsyncQueue {
        connectionQueues.withLock { queues in
            if let queue = queues[connection] {
                return queue
            }
            let queue = AsyncQueue(attributes: [.concurrent])
            queues[connection] = queue
            return queue
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

    @XPCActor var xpcConnection: SwiftyXPC.XPCConnection?
    private let attemptReconnect: Bool
    private let connectionType: ConnectionType
    private let codeSigningRequirement: CodeSigningRequirement?

    public init(
        attemptReconnect: Bool = true,
        connectionType: ConnectionType,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any ActorRequirement)?
        )? = nil
    )
    async throws {
        self.attemptReconnect = attemptReconnect
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

    @XPCActor func shutdown() async throws {
        guard let xpcConnection else { return }
        try await xpcConnection.cancel()
        connectionQueues.withLock { $0.values.forEach { $0.cancelAllPendingTasks() } }
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
        connection.cancelHandler = { [weak self] in
            guard let self else { return }
            await onConnectionInvalidated()
        }
        connection.errorHandler = { [weak self] _, _ in
            guard let self else { return }
            await onConnectionInvalidated()
        }

        connection.setMessageHandler(name: "invoke") {
            [weak self] (connection: SwiftyXPC.XPCConnection, request: InvocationRequest)
            async throws -> InvocationResponse<Data> in
            guard let self else {
                return InvocationResponse<Data>(error: "Server unavailable", value: nil)
            }
            return try await withDependencies {
                $0.distributedActorSystem = self
            } operation: {
                try await self.onConnectionQueue(connection) {
                    await self.handleInvocation(request: request)
                }
            }
        }
    }

    @XPCActor private func onConnectionInvalidated() async {
        state.withLock { $0 = .disconnected }
        if let connection = xpcConnection {
            await connectionClose(connection: connection)
        }
        // Automatically reconnect for client connections
        // do this in a task so the error handler can resolve before attempting to re-connect
        guard attemptReconnect else { return }
        Task {
            try? await connect()
        }
    }

    override public func remoteCall<Act, Res>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: ActorRequirement, Act.ID == ActorID, Res: Codable
    {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }

        let response: InvocationResponse<Data> = try await withDependencies {
            $0.distributedActorSystem = self
        } operation: {
            await invocation.waitForAsyncStreamEncoding()
            let request = try await onConnectionQueue(xpcConnection) { [target, invocation] in
                InvocationRequest(
                    actorId: actor.id, target: target.identifier, invocation: invocation,
                )
            }
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
        async throws where Act: ActorRequirement, Act.ID == ActorID
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

    override func onConnectionClose(
        connection: SwiftyXPC.XPCConnection? = nil,
        _ callback: @escaping @Sendable () async -> Void,
    ) async {
        var connection = connection
        if connection == nil {
            connection = await xpcConnection
        }
        await super.onConnectionClose(connection: connection, callback)
    }
}

// MARK: - Server System

public final class XPCDistributedActorServer: XPCDistributedActorSystem, @unchecked Sendable {
    public enum Event: Codable, Sendable {
        case readyForShutdown
    }

    public typealias EventHandler = @Sendable (Event) async -> Void
    private let eventHandler: EventHandler
    private let eventQueue: AsyncQueue = .init()

    @XPCActor private let activeConnections: Mutex<[SwiftyXPC.XPCConnection]> = .init([])
    @XPCActor private var listener: SwiftyXPC.XPCListener?

    public init(
        listener: SwiftyXPC.XPCListener,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any ActorRequirement)?
        )? = nil,
        eventHandler: @escaping EventHandler = { _ in }
    )
    async throws {
        self.eventHandler = eventHandler
        super.init(actorCreationHandler: actorCreationHandler)
        try await startListening(listener: listener)
    }

    /// Convenience initializer for daemon services
    public init(
        daemonServiceName: String,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any ActorRequirement)?
        )? = nil,
        eventHandler: @escaping EventHandler = { _ in }
    )
    async throws {
        let listener = try SwiftyXPC.XPCListener(
            type: .machService(name: daemonServiceName),
            codeSigningRequirement: codeSigningRequirement?.requirement,
        )
        self.eventHandler = eventHandler
        super.init(actorCreationHandler: actorCreationHandler)
        try await startListening(listener: listener)
    }

    /// Convenience initializer for XPC services
    public init(
        xpcService _: Bool = true,
        codeSigningRequirement: CodeSigningRequirement? = nil,
        actorCreationHandler: (
            @Sendable (XPCDistributedActorSystem) async throws -> (any ActorRequirement)?
        )? = nil,
        eventHandler: @escaping EventHandler = { _ in }
    )
    async throws {
        let listener = try SwiftyXPC.XPCListener(
            type: .service,
            codeSigningRequirement: codeSigningRequirement?.requirement,
        )
        self.eventHandler = eventHandler
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
            await handleNewConnection(newConnection)
        }
        listener.canceledConnectionHandler = { [weak self] connection in
            guard let self else { return }
            await removeConnection(connection)
        }
    }

    @XPCActor private func handleNewConnection(_ connection: SwiftyXPC.XPCConnection) async {
        activeConnections.withLock {
            $0.append(connection)
        }
        setupConnectionHandlers(connection)

        do {
            try await connection.activate()
        } catch {
            await removeConnection(connection)
        }
    }

    @XPCActor private func setupConnectionHandlers(_ connection: SwiftyXPC.XPCConnection) {
        connection.cancelHandler = { [weak self] in
            guard let self else { return }
            await removeConnection(connection)
        }
        connection.errorHandler = { [weak self] connection, _ in
            guard let self else { return }
            await removeConnection(connection)
        }

        connection.setMessageHandler(name: "invoke") {
            [weak self] (connection: SwiftyXPC.XPCConnection, request: InvocationRequest)
            async throws -> InvocationResponse<Data> in
            guard let self else {
                return InvocationResponse<Data>(error: "Server unavailable", value: nil)
            }
            return try await withDependencies {
                $0.distributedActorSystem = self
            } operation: {
                try await self.onConnectionQueue(connection) {
                    await self.handleInvocation(request: request)
                }
            }
        }
    }

    @XPCActor private func removeConnection(_ connection: SwiftyXPC.XPCConnection) async {
        guard activeConnections.withLock({ $0.contains(where: { $0 === connection }) }) else {
            return
        }
        try! await onConnectionQueue(connection) {
            await self.connectionClose(connection: connection)
        }
        activeConnections.withLock { $0.removeAll { $0 === connection } }
        if activeConnections.withLock({ $0.isEmpty }) {
            await eventQueue.addOperation { [eventHandler] in
                await eventHandler(.readyForShutdown)
            }.value
        }
    }

    override public func remoteCall<Act, Res>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: ActorRequirement, Act.ID == ActorID, Res: Codable
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
        async throws where Act: ActorRequirement, Act.ID == ActorID
    {
        // Server systems typically don't make remote calls, but if needed, this could be implemented
        // to call out to other services
        throw ProtocolError.noConnection
    }

    enum ShutdownError: Swift.Error {
        case danglingActiveConnections, danglingCodableAsyncStreams, danglingCreatedActors, danglingInvocations,
             danglingLiveActors
    }

    public func wantsShutdown() async throws {
        let semaphore: AsyncSemaphore = .init(value: 0)
        /// flush `eventQueue`
        eventQueue.addBarrierOperation {
            semaphore.signal()
        }
        await semaphore.wait()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await Task.sleep(for: .milliseconds(10))
                try Task.checkCancellation()
                return true
            }
            group.addTask { [weak self] in
                guard let self else { return false }
                while invocations.withLock({ $0.count }) > 0 {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return false
            }
            let needsForcedCancellation = try await group.next()!
            group.cancelAll()
            if needsForcedCancellation {
                invocations.withLock {
                    for (_, semaphore) in $0 {
                        semaphore.signal()
                    }
                }
                try await Task.sleep(for: .milliseconds(10))
                connectionQueues.withLock {
                    for queue in $0.values {
                        queue.cancelAllPendingTasks()
                    }
                }
                try await Task.sleep(for: .milliseconds(1))
                if invocations.withLock({ $0.count }) > 0 {
                    throw ShutdownError.danglingInvocations
                }
            }
        }
        try createdActors.withLock {
            guard $0.isEmpty else {
                throw ShutdownError.danglingCreatedActors
            }
        }
        try liveActorStorage.actors.withLock {
            guard $0.isEmpty else {
                throw ShutdownError.danglingLiveActors
            }
        }
        try activeConnections.withLock {
            guard $0.isEmpty else {
                throw ShutdownError.danglingActiveConnections
            }
        }
    }
}

extension XPCDistributedActorSystem: DependencyKey {
    public static var liveValue: XPCDistributedActorSystem? { nil }
    public static var testValue: XPCDistributedActorSystem? { nil }
}

extension AsyncSemaphore: @retroactive DependencyKey {
    public static var liveValue: AsyncSemaphore {
        print(Thread.callStackSymbols.joined(separator: "\n"))
        fatalError("XPCDistributedActorSystem must be provided via withDependencies")
    }

    public static var testValue: AsyncSemaphore {
        print(Thread.callStackSymbols.joined(separator: "\n"))
        fatalError("XPCDistributedActorSystem must be provided via withDependencies")
    }
}

extension SwiftyXPC.XPCConnection: @retroactive DependencyKey {
    public static var liveValue: XPCConnection? { nil }
    public static var testValue: XPCConnection? { nil }
}

extension SwiftyXPC.XPCConnection: @retroactive Hashable {
    public static func == (lhs: SwiftyXPC.XPCConnection, rhs: SwiftyXPC.XPCConnection) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
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

extension RemoteCallTarget: @unchecked @retroactive Sendable {}
