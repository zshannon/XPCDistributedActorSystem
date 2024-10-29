import Foundation
import Distributed

public struct InvocationRequest: Codable, Sendable
{
    let actorId: XPCDistributedActorSystem.ActorID
    let target: String
    let arguments: [Data]
    let genericSubstitutions: [String]
    let returnType: String?
    let errorType: String?
    
    init(actorId: XPCDistributedActorSystem.ActorID, target: String, invocation: GenericInvocationEncoder)
    {
        self.actorId = actorId
        self.target = target
        self.arguments = invocation.arguments
        self.genericSubstitutions = invocation.generics
        self.returnType = invocation.returnType
        self.errorType = invocation.errorType
    }
}
