import Foundation
import Distributed
import Synchronization

public final class XPCDistributedActorSystem : DistributedActorSystem
{
    public enum Mode: Equatable, Sendable {
        case mainListener
        case anonymousListener
        case daemonListener(service: String)
        case client(service: String)
    }

    enum ProtocolError: Swift.Error, LocalizedError {
        case failedToFindValueInResponse
        case errorFromRemoteActor(String)
        case failedToFindActorForId(ActorID)
        
        var errorDescription: String? {
            switch self {
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
    
    let xpcConnection: XPCConnection
    let liveActorStorage = LiveActorStorage()

    let nextActorId: Mutex<[ObjectIdentifier:Int]> = .init([:])
    
    public init(mode: Mode)
    {
        switch mode {
        case .mainListener:
            self.xpcConnection = XPCConnection.main
        case .anonymousListener:
            self.xpcConnection = XPCConnection(mode: .anonymousListener)
        case .daemonListener(let service):
            self.xpcConnection = XPCConnection(mode: .daemonListener(service: service))
        case .client(let service):
            self.xpcConnection = XPCConnection(mode: .client(service: service))
        }

        self.xpcConnection.setHandler(handleIncomingInvocation)
    }

    public func startXpcMainAndBlock() -> Never
    {
        self.xpcConnection.startMainAndBlock()
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
        let request = InvocationRequest(actorId: actor.id, target: target.identifier, invocation: invocation)
        let response = try await self.xpcConnection.send(request, expect: InvocationResponse<Res>.self)
        
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
        let request = InvocationRequest(actorId: actor.id, target: target.identifier, invocation: invocation)
        let response = try await self.xpcConnection.send(request, expect: InvocationResponse<Never>.self)

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
