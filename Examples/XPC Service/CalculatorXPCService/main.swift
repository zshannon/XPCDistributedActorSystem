import Calculator
import XPCDistributedActorSystem

let server = try await XPCDistributedActorServer(
    xpcService: true,
    codeSigningRequirement: try .sameTeam,
    actorCreationHandler: { system in
        // Create a Calculator actor when one isn't found for the given ID
        return Calculator(actorSystem: system)
    }
)
