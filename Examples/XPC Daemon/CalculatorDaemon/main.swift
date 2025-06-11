import Calculator
import Foundation
import XPCDistributedActorSystem

let server = try await XPCDistributedActorServer(
    daemonServiceName: daemonXPCServiceIdentifier,
    codeSigningRequirement: .sameTeam,
    actorCreationHandler: { system in
        // Create a Calculator actor when one isn't found for the given ID
        Calculator(actorSystem: system)
    },
)
