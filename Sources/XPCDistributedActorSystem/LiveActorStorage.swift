import Distributed
import Foundation
import Synchronization

final class LiveActorStorage: Sendable {
    class Reference {
        weak var actor: (any DistributedActor)?

        init(to actor: (any DistributedActor)? = nil) {
            self.actor = actor
        }
    }

    let actors: Mutex<[XPCDistributedActorSystem.ActorID: Reference]> = .init([:])

    func add<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == XPCDistributedActorSystem.ActorID {
        actors.withLock {
            $0[actor.id] = Reference(to: actor)
        }
    }

    func get(_ id: XPCDistributedActorSystem.ActorID) -> (any DistributedActor)? {
        actors.withLock {
            $0[id]?.actor
        }
    }

    func get<Act>(_ id: XPCDistributedActorSystem.ActorID, as _: Act.Type) -> Act? {
        actors.withLock {
            $0[id]?.actor as? Act
        }
    }

    func remove(_ id: XPCDistributedActorSystem.ActorID) -> (any DistributedActor)? {
        actors.withLock {
            $0.removeValue(forKey: id)?.actor
        }
    }
}
