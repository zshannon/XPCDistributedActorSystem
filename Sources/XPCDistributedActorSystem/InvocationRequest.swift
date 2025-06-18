import Dependencies
import Distributed
import Foundation

public struct InvocationRequest: Codable, Sendable {
    let actorId: XPCDistributedActorSystem.ActorID
    let id: UUID
    let target: String
    let arguments: [Data]
    let genericSubstitutions: [String]
    let returnType: String?
    let errorType: String?

    init(actorId: XPCDistributedActorSystem.ActorID, target: String, invocation: GenericInvocationEncoder) {
        self.actorId = actorId
        self.target = target
        @Dependency(\.requestId) var requestId
        id = requestId ?? .init()
        arguments = invocation.arguments
        genericSubstitutions = invocation.generics
        returnType = invocation.returnType
        errorType = invocation.errorType
    }
}
