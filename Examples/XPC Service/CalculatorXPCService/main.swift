import XPCDistributedActorSystem
import Calculator

let system = XPCDistributedActorSystem(mode: .mainListener)
let calculator = Calculator(actorSystem: system)
system.startXpcMainAndBlock()
