import Dependencies
import Distributed
import Foundation
import Semaphore
@preconcurrency import SwiftyXPC
import Synchronization

public final class XPCDistributedActorClient: XPCDistributedActorSystem, @unchecked Sendable {
    public enum ConnectionType: Sendable {
        case daemon(serviceName: String)
        case xpcService(serviceName: String)
        case endpoint(SwiftyXPC.XPCEndpoint)
    }

    private let codeSigningRequirement: CodeSigningRequirement?
    private let connectionType: ConnectionType
    fileprivate let createdActors: Mutex<[ActorID: any DistributedActor]> = .init([:])
    private let liveActorStorage = LiveActorStorage()
    fileprivate let state: Mutex<XPCDistributedActorSystem.State> = .init(.disconnected)

    @XPCActor private var xpcConnection: SwiftyXPC.XPCConnection?

    override var isServer: Bool {
        false
    }

    public init(
        connectionType: ConnectionType,
        codeSigningRequirement: CodeSigningRequirement? = nil
    )
    async throws {
        self.codeSigningRequirement = codeSigningRequirement
        self.connectionType = connectionType
        super.init()
        try await connect()
    }

    override public func actorReady<Act>(_ actor: Act) where Act: DistributedActor,
        XPCDistributedActorSystem.ActorID == Act.ID
    {
        liveActorStorage.add(actor)
    }

    override public func resolve<Act>(id: XPCDistributedActorSystem.ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor, XPCDistributedActorSystem.ActorID == Act.ID
    {
        return liveActorStorage.get(id, as: actorType.self)
    }
    
    override public func assignID<Act>(_: Act.Type) -> ActorID
        where Act: DistributedActor, ActorID == Act.ID
    {
        @Dependency(\.nextActorID) var nextActorID
        let id: ActorID = nextActorID ?? .init()
        return id
    }
    
    override public func resignID(_ id: XPCDistributedActorSystem.ActorID) {
        liveActorStorage.remove(id)
    }

    override public func makeInvocationEncoder() -> InvocationEncoder {
        InvocationEncoder(system: self)
    }

    override public func remoteCall<Act, Res>(
        on actor: Act, target: RemoteCallTarget, invocation: inout XPCDistributedActorSystem.InvocationEncoder,
        throwing _: (some Error).Type, returning _: Res.Type
    )
        async throws -> Res where Act: DistributedActor, Act.ID == XPCDistributedActorSystem.ActorID, Res: Codable
    {
        guard let xpcConnection = await xpcConnection
        else { throw XPCDistributedActorSystem.ProtocolError.noConnection }

        let request = InvocationRequest(
            actorId: actor.id, target: target.identifier, invocation: invocation,
        )

        let response: InvocationResponse<Data> = try await withDependencies {
            $0.actorSystem = self
        } operation: {
            try await xpcConnection.sendMessage(
                name: "invoke", request: request,
            )
        }

        if let error = response.error {
            throw XPCDistributedActorSystem.ProtocolError.errorFromRemoteActor(error)
        }

        guard let valueData = response.value else {
            throw XPCDistributedActorSystem.ProtocolError.failedToFindValueInResponse
        }

        let semaphore: AsyncSemaphore = .init(value: 0)
        return try await withDependencies {
            $0.actorSystem = self
            $0.casSemaphore = semaphore
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
        on actor: Act, target: RemoteCallTarget, invocation: inout XPCDistributedActorSystem.InvocationEncoder,
        throwing _: (some Error).Type
    )
        async throws where Act: DistributedActor, Act.ID == XPCDistributedActorSystem.ActorID
    {
        guard let xpcConnection = await xpcConnection
        else { throw XPCDistributedActorSystem.ProtocolError.noConnection }

        let request = InvocationRequest(
            actorId: actor.id, target: target.identifier, invocation: invocation,
        )
        let response: InvocationResponse<Data> = try await xpcConnection.sendMessage(
            name: "invoke", request: request,
        )

        if let error = response.error {
            throw XPCDistributedActorSystem.ProtocolError.errorFromRemoteActor(error)
        }
    }

//    public func remoteCall<Act, Res>(
//        on _: Act, target _: RemoteCallTarget, invocation _: inout XPCDistributedActorSystem.InvocationEncoder,
//        throwing _: (some Error).Type, returning _: Res.Type
//    )
//    async throws -> Res where Act: DistributedActor, Act.ID == XPCDistributedActorSystem.ActorID, Res: Codable
//    {
//        fatalError("Must be implemented by subclass")
//    }

    // swiftformat:disable:next opaqueGenericParameters,unusedArguments
//    override public func remoteCall<Act, Err, Res>(
//        on actor: Act,
//        target: RemoteCallTarget,
//        invocation: inout XPCDistributedActorSystem.InvocationEncoder,
//        throwing: Err.Type,
//        returning: Res.Type
//    ) async throws -> Res
//        where Act: DistributedActor, Act.ID == XPCDistributedActorSystem.ActorID, Err: Error,
//        Res: XPCDistributedActorSystem.SerializationRequirement
//    {
//        fatalError("Must be implemented by subclass")
//    }

//    public func remoteCallVoid<Act>(
//        on _: Act, target _: RemoteCallTarget, invocation _: inout XPCDistributedActorSystem.InvocationEncoder,
//        throwing _: (some Error).Type
//    )
//    async throws where Act: DistributedActor, Act.ID == XPCDistributedActorSystem.ActorID
//    {
//        fatalError("Must be implemented by subclass")
//    }
}

extension XPCDistributedActorClient {
    func shutdown() async {
        await withCheckedContinuation { continuation in
            Task { @XPCActor in
                try? await self.xpcConnection?.cancel()
                self.xpcConnection = nil
                self.state.withLock { $0 = .disconnected }
                continuation.resume()
            }
        }
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
}
