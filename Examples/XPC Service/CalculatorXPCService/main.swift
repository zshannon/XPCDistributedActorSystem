import XPCDistributedActorSystem
import Calculator

let system = XPCDistributedActorSystem(mode: .receivingConnections, codeSigningRequirement: try .sameTeam)
let calculator = Calculator(actorSystem: system)
let listener = try XPCServiceListener(actorSystem: system)
listener.run()
