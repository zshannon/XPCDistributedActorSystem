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

    public func actorReady<Act>(_: Act) where Act: DistributedActor, ActorID == Act.ID {
        fatalError("subclass must override")
    }

    public func assignID<Act>(_: Act.Type) -> ActorID
        where Act: DistributedActor, ActorID == Act.ID
    {
        fatalError("subclass must override")
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        fatalError("subclass must override")
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
}
