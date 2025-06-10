import Distributed
import Foundation
@preconcurrency import SwiftyXPC
import Synchronization

@propertyWrapper
public struct UnsafeSendable<Value>: @unchecked Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

public final class XPCDistributedActorSystem: DistributedActorSystem {
    public enum State: Sendable {
        case connecting
        case connected
        case disconnected
    }

    public enum Mode: Sendable {
        case receivingConnections(listener: SwiftyXPC.XPCListener)
        case connectingToDaemon(serviceName: String)
        case connectingToXPCService(serviceName: String)
        case connectingToEndpoint(endpoint: SwiftyXPC.XPCEndpoint)

        var canReconnect: Bool {
            switch self {
            case .connectingToDaemon, .connectingToXPCService:
                return true
            default:
                return false
            }
        }
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
            case .errorFromRemoteActor(let string):
                "Remote: \(string)"
            case .failedToFindActorForId(let actorID):
                "Failed to find actor for ID \(actorID)"
            }
        }
    }

    public typealias ActorID = Int
    public typealias InvocationEncoder = GenericInvocationEncoder
    public typealias InvocationDecoder = GenericInvocationDecoder
    public typealias ResultHandler = InvocationResultHandler
    public typealias SerializationRequirement = any Codable

    @XPCActor private var xpcConnection: SwiftyXPC.XPCConnection?
    @XPCActor private var listener: SwiftyXPC.XPCListener?

    let liveActorStorage = LiveActorStorage()
    let nextActorId: Mutex<[ObjectIdentifier: Int]> = .init([:])
    let codeSigningRequirement: CodeSigningRequirement?
    let mode: Mode
    let state: Mutex<State> = .init(.disconnected)
    let actorCreationHandler:
        (@Sendable (XPCDistributedActorSystem) async throws -> (any DistributedActor)?)?

    // Strong references to actors created via handler to keep them alive
    let createdActors: Mutex<[ActorID: any DistributedActor]> = .init([:])

    // Thread-local storage for overriding the next assigned ID
    @TaskLocal static var pendingActorID: ActorID?

    public init(mode: Mode, codeSigningRequirement: CodeSigningRequirement?) {
        self.codeSigningRequirement = codeSigningRequirement
        self.mode = mode
        self.actorCreationHandler = nil

        connect()
    }

    public init(
        mode: Mode, codeSigningRequirement: CodeSigningRequirement?,
        actorCreationHandler: @escaping @Sendable (XPCDistributedActorSystem) async throws -> (
            any DistributedActor
        )?
    ) {
        self.codeSigningRequirement = codeSigningRequirement
        self.mode = mode
        self.actorCreationHandler = actorCreationHandler

        connect()
    }

    func connect() {
        self.state.withLock { $0 = .connecting }
        Task { @XPCActor in
            do {
                switch mode {
                case .receivingConnections(listener: let xpcListener):
                    self.listener = xpcListener
                    xpcListener.activatedConnectionHandler = { [weak self] newConnection in
                        guard let self = self else { return }
                        Task { @XPCActor in
                            do {
                                self.xpcConnection = newConnection
                                self.setupConnectionHandlers(newConnection)
                                try await newConnection.activate()
                                self.state.withLock { $0 = .connected }
                            } catch {
                                self.state.withLock { $0 = .disconnected }
                            }
                        }
                    }
                    xpcListener.activate()
                    self.state.withLock { $0 = .connected }
                case .connectingToDaemon(let serviceName):
                    let connection = try SwiftyXPC.XPCConnection(
                        type: .remoteMachService(
                            serviceName: serviceName, isPrivilegedHelperTool: true),
                        codeSigningRequirement: codeSigningRequirement?.requirement)
                    self.xpcConnection = connection
                    self.setupConnectionHandlers(connection)
                    try await connection.activate()
                    self.state.withLock { $0 = .connected }
                case .connectingToXPCService(let serviceName):
                    let connection = try SwiftyXPC.XPCConnection(
                        type: .remoteService(bundleID: serviceName),
                        codeSigningRequirement: codeSigningRequirement?.requirement)
                    self.xpcConnection = connection
                    self.setupConnectionHandlers(connection)
                    try await connection.activate()
                    self.state.withLock { $0 = .connected }
                case .connectingToEndpoint(let endpoint):
                    let connection = try SwiftyXPC.XPCConnection(
                        type: .remoteServiceFromEndpoint(endpoint),
                        codeSigningRequirement: codeSigningRequirement?.requirement)
                    self.xpcConnection = connection
                    self.setupConnectionHandlers(connection)
                    try await connection.activate()
                    self.state.withLock { $0 = .connected }
                }
            } catch {
                self.state.withLock { $0 = .disconnected }
            }
        }
    }

    nonisolated func setConnection(_ connection: SwiftyXPC.XPCConnection?) {
        Task { @XPCActor in
            self.xpcConnection = connection
            if let connection = connection {
                self.setupConnectionHandlers(connection)
            }
        }
    }

    @XPCActor private func setupConnectionHandlers(_ connection: SwiftyXPC.XPCConnection) {
        connection.errorHandler = { [weak self] _, error in
            guard let self else { return }
            Task { @XPCActor in
                self.onConnectionInvalidated()
            }
        }

        connection.setMessageHandler(name: "invoke") {
            [weak self] (connection: SwiftyXPC.XPCConnection, request: InvocationRequest)
                async throws -> InvocationResponse<Data> in
            guard let self else {
                return InvocationResponse<Data>(error: "invalid state", value: nil)
            }
            return await self.handleInvocation(request: request)
        }
    }

    func onConnectionInvalidated() {
        self.state.withLock { $0 = .disconnected }

        // The XPC connection becomes invalid if the specified service couldn't be found in the XPC service namespace.
        // Usually, this is because of a misconfiguration. However, there are scenarios where invalidations happen and need to be dealt with.
        // Example: After loading a deamon, its XPC listener isn't quite ready when trying to connect immediately.
        // In these cases, it's reasonable to try to reconnect.

        if self.mode.canReconnect {
            connect()
        }
    }

    func handleInvocation(request: InvocationRequest) async -> InvocationResponse<Data> {
        do {
            var localActor = self.liveActorStorage.get(request.actorId)

            if localActor == nil, let actorCreationHandler = self.actorCreationHandler {
                // Double-checked locking pattern for actor creation
                localActor = self.liveActorStorage.actors.withLock { actors in
                    if let existingRef = actors[request.actorId],
                        let existingActor = existingRef.actor
                    {
                        return existingActor
                    }
                    return nil
                }

                if localActor == nil {
                    // Set the pending actor ID so assignID() will use it
                    let newActor = try await XPCDistributedActorSystem.$pendingActorID.withValue(
                        request.actorId
                    ) {
                        try await actorCreationHandler(self)
                    }

                    if let actor = newActor {
                        // Store strong reference to keep actor alive
                        self.createdActors.withLock { createdActors in
                            createdActors[request.actorId] = actor
                        }
                        localActor = actor
                    }
                }
            }

            guard let localActor else {
                throw ProtocolError.failedToFindActorForId(request.actorId)
            }

            var invocationDecoder = InvocationDecoder(system: self, request: request)
            let handler = InvocationResultHandler()

            try await self.executeDistributedTarget(
                on: localActor,
                target: RemoteCallTarget(request.target),
                invocationDecoder: &invocationDecoder,
                handler: handler
            )

            return handler.response ?? InvocationResponse<Data>(error: nil, value: nil)
        } catch {
            return InvocationResponse<Data>(error: error)
        }
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        InvocationEncoder()
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing: Err.Type, returning: Res.Type
    ) async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }

        let request = InvocationRequest(
            actorId: actor.id, target: target.identifier, invocation: invocation)
        let response: InvocationResponse<Data> = try await xpcConnection.sendMessage(
            name: "invoke", request: request)

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }

        guard let valueData = response.value else {
            throw ProtocolError.failedToFindValueInResponse
        }

        return try JSONDecoder().decode(Res.self, from: valueData)
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }

        let request = InvocationRequest(
            actorId: actor.id, target: target.identifier, invocation: invocation)
        let response: InvocationResponse<Data> = try await xpcConnection.sendMessage(
            name: "invoke", request: request)

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        liveActorStorage.add(actor)
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, ActorID == Act.ID {
        liveActorStorage.get(id, as: actorType.self)
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Int == Act.ID {
        // Check if there's a pending actor ID to use (for actor creation handler)
        if let pendingID = XPCDistributedActorSystem.pendingActorID {
            return pendingID
        }

        var id: Int?

        nextActorId.withLock { dictionary in
            let nextId = dictionary[ObjectIdentifier(actorType)] ?? 1
            dictionary[ObjectIdentifier(actorType)] = nextId + 1
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
}
