import Calculator
import XPCDistributedActorSystem

let system = XPCDistributedActorSystem(
    mode: .receivingConnections, codeSigningRequirement: try .sameTeam)
let calculator = Calculator(actorSystem: system)
let listener = try XPCServiceListener(
    listener: XPCListener(
        type: .service, codeSigningRequirement: system.codeSigningRequirement?.requirement),
    actorSystem: system)
listener.run()
