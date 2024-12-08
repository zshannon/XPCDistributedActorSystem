import Foundation
import Calculator
import XPCDistributedActorSystem

let system = XPCDistributedActorSystem(mode: .receivingConnections)
let calculator = Calculator(actorSystem: system)
let listener = try XPCDaemonListener(daemonServiceName: daemonXPCServiceIdentifier, actorSystem: system)

dispatchMain()
