import Foundation
import Distributed
import Synchronization

public final class XPCDistributedActorSystem : DistributedActorSystem
{
    public enum State: Sendable {
        case connecting
        case connected
        case disconnected
    }
    
    public enum Mode: Sendable {
        case receivingConnections
        case connectingToDaemon(serviceName: String)
        case connectingToXPCService(serviceName: String)
        
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
    
    @XPCActor private var xpcConnection: XPCConnection?
    
    let liveActorStorage = LiveActorStorage()
    let nextActorId: Mutex<[ObjectIdentifier:Int]> = .init([:])
    let codeSigningRequirement: CodeSigningRequirement?
    let mode: Mode
    let state: Mutex<State> = .init(.disconnected)
    
    public init(mode: Mode, codeSigningRequirement: CodeSigningRequirement?)
    {
        self.codeSigningRequirement = codeSigningRequirement
        self.mode = mode
        
        connect()
    }
    
    func connect()
    {
        self.state.withLock { $0 = .connecting }
        Task { @XPCActor in
            switch mode {
            case .receivingConnections:
                break
            case .connectingToDaemon(serviceName: let serviceName):
                self.xpcConnection = XPCConnection(daemonServiceName: serviceName, actorSystem: self, codeSigningRequirement: codeSigningRequirement)
                self.state.withLock { $0 = .connected }
            case .connectingToXPCService(serviceName: let serviceName):
                self.xpcConnection = XPCConnection(serviceName: serviceName, actorSystem: self, codeSigningRequirement: codeSigningRequirement)
                self.state.withLock { $0 = .connected }
            }
        }
    }
    
    nonisolated func setConnection(_ connection: XPCConnection?)
    {
        Task { @XPCActor in
            self.xpcConnection = connection
        }
    }
    
    func onConnectionInvalidated()
    {
        self.state.withLock { $0 = .disconnected }
        
        // The XPC connection becomes invalid if the specified service couldn't be found in the XPC service namespace.
        // Usually, this is because of a misconfiguration. However, there are scenarios where invalidations happen and need to be dealt with.
        // Example: After loading a deamon, its XPC listener isn't quite ready when trying to connect immediately.
        // In these cases, it's reasonable to try to reconnect.
        
        if self.mode.canReconnect {
            connect()
        }
    }

    func handleIncomingInvocation(connection: XPCConnection, message: XPCMessageWithObject)
    {
        Task {
            do {
                let invocationRequest = try message.extract(InvocationRequest.self)
                
                guard let localActor = self.liveActorStorage.get(invocationRequest.actorId) else {
                    throw ProtocolError.failedToFindActorForId(invocationRequest.actorId)
                }
                
                var invocationDecoder = InvocationDecoder(system: self, request: invocationRequest)
                
                try await self.executeDistributedTarget(
                    on: localActor,
                    target: RemoteCallTarget(invocationRequest.target),
                    invocationDecoder: &invocationDecoder,
                    handler: ResultHandler(xpcConnection: connection, request: message)
                )
            } catch {
                let response = InvocationResponse(error: error)
                let messageToSend = try XPCMessageWithObject(from: response, replyTo: message)
                try await connection.reply(with: messageToSend)
            }
        }
    }

    public func makeInvocationEncoder() -> InvocationEncoder
    {
        InvocationEncoder()
    }
    
    public func remoteCall<Act, Err, Res>(on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder, throwing: Err.Type, returning: Res.Type) async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable
    {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }
        
        let request = InvocationRequest(actorId: actor.id, target: target.identifier, invocation: invocation)
        let response = try await xpcConnection.send(request, expect: InvocationResponse<Res>.self)
        
        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }
        
        guard let value = response.value else {
            throw ProtocolError.failedToFindValueInResponse
        }
        
        return value
    }
    
    public func remoteCallVoid<Act, Err>(on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder, throwing: Err.Type) async throws where Act: DistributedActor, Act.ID == ActorID, Err: Error 
    {
        guard let xpcConnection = await xpcConnection else { throw ProtocolError.noConnection }

        let request = InvocationRequest(actorId: actor.id, target: target.identifier, invocation: invocation)
        let response = try await xpcConnection.send(request, expect: InvocationResponse<Never>.self)

        if let error = response.error {
            throw ProtocolError.errorFromRemoteActor(error)
        }
    }
    
    public func actorReady<Act>(_ actor: Act) where Act : DistributedActor, ActorID == Act.ID
    {
        liveActorStorage.add(actor)
    }
    
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act? where Act : DistributedActor, ActorID == Act.ID
    {
        liveActorStorage.get(id, as: actorType.self)
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID where Act : DistributedActor, Int == Act.ID
    {
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
    
    public func resignID(_ id: XPCDistributedActorSystem.ActorID)
    {
        liveActorStorage.remove(id)
    }
}
