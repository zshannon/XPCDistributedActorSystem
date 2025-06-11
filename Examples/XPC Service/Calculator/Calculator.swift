import Distributed
import XPCDistributedActorSystem

distributed public actor Calculator {
    public typealias ActorSystem = XPCDistributedActorSystem

    public init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    distributed public func add(_ value1: Int, _ value2: Int) -> Int {
        value1 + value2
    }

    distributed public func justARemoteFunction() {
        print("`justARemoteFunction` was called")
    }
}
