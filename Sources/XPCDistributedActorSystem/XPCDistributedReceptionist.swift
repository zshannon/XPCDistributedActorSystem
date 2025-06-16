import Distributed
// import DistributedCluster
import Foundation
import Synchronization

// MARK: - HelloWorld Actor

distributed actor HelloWorld: CustomStringConvertible {
    typealias ActorSystem = XPCDistributedActorSystem

    distributed func greet(_ name: String) -> String {
        print("greet", actorSystem)
        return "Hello, \(name)!"
    }

    distributed func getID() -> ActorSystem.ActorID {
        id
    }
    
    nonisolated public var description: String {
        "\(String(reflecting: Self.self))(id: \(id))"
    }
}

/// A type‑erased wrapper that guarantees the wrapped `DistributedActor`
/// uses the same `ActorSystem` as the enclosing receptionist.
private struct AnyGuest<AS: DistributedActorSystem>: Sendable {
    let ref: any DistributedActor
    init<A: DistributedActor>(_ guest: A) where A.ActorSystem == AS {
        ref = guest
    }

    var id: AS.ActorID {
        ref.id as! AS.ActorID
    }
}

extension TypedUUID {
    static let receptionist: Self = .init(
        uuid: "XPCDistributedReceptionist",
        type: String(reflecting: XPCDistributedReceptionist.self)
    )
}

public distributed actor XPCDistributedReceptionist {
    public typealias ActorSystem = XPCDistributedActorSystem

    private var guests: [String: [AnyGuest<ActorSystem>]] = [:]

    public init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    public static func resolve(using system: ActorSystem) throws -> XPCDistributedReceptionist {
        return try resolve(id: .receptionist, using: system)
    }

    public distributed func checkIn<Guest>(_ guest: Guest, with key: DistributedReception.Key<Guest>) async
        where Guest: DistributedActor & Codable, ActorSystem == Guest.ActorSystem
    {
        await whenLocal { local in
            local.localCheckIn(guest, with: key)
        }
    }

//    public distributed func get(_ id: ActorSystem.ActorID) async -> (any Codable & DistributedActor)?
//    {
//        print(".get", id, guests)
//        return nil
//    }

    enum XPCDistributedReceptionistError: Swift.Error {
        case notFound
    }

    nonisolated func get(_ id: ActorSystem.ActorID) async -> (any DistributedActor)? {
        print("GEETTTTT", id, self.actorSystem)
        return try? HelloWorld.resolve(id: id, using: actorSystem)
        return try! await whenLocal { local in
            guard let wrapped = local.guests.values.flatMap({ $0 }).first(where: { id == $0.id }) else {
                print("NOT FOUND!!")
                throw XPCDistributedReceptionistError.notFound
            }
            print(".get", id, local.guests, wrapped.ref)
            return wrapped.ref
        }
    }
    
    distributed func LOL() async {
        print("LOL", id)
    }

    private func localCheckIn<Guest>(_ guest: Guest, with key: DistributedReception.Key<Guest>)
        where Guest: DistributedActor, ActorSystem == Guest.ActorSystem
    {
        print("localCheckIn", guest, key)
        guests[key.id, default: []].append(AnyGuest<ActorSystem>(guest))
        print(guests)
        Task {
            let rep = try XPCDistributedReceptionist.resolve(using: actorSystem)
            print("resolved receptionist", rep, rep.id)
            try await rep.LOL()
        }
    }

    public distributed func lookup<Guest>(_ key: DistributedReception.Key<Guest>) async -> Set<Guest>
        where Guest: DistributedActor & Codable, ActorSystem == Guest.ActorSystem
    {
        await whenLocal { local in
            let candidates = local.guests[key.id] ?? []
            return Set<Guest>(candidates.compactMap { $0.ref as? Guest })
        } ?? Set<Guest>()
    }
}

public enum DistributedReception {}

public extension DistributedReception {
    /// Used to register and lookup actors in the receptionist.
    /// The key is a combination the Guest's type and an identifier to identify sub-groups of actors of that type.
    ///
    /// The id defaults to "*" which can be used "all actors of that type" (if and only if they registered using this
    /// key,
    /// actors which do not opt-into discovery by registering themselves WILL NOT be discovered using this, or any
    /// other, key).
    struct Key<Guest>: Codable, Sendable,
        ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
        CustomStringConvertible
    {
        public let id: String
        public var guestType: Any.Type {
            Guest.self
        }

        public init(_: Guest.Type = Guest.self, id: String = "*") {
            self.id = id
        }

        public init(stringLiteral value: StringLiteralType) {
            id = value
        }

//        internal func resolve(system: XPCDistributedActorSystem, id: ActorID) -> _AddressableActorRef {
//            let ref: _ActorRef<InvocationMessage> = system._resolve(context: _ResolveContext(id: id, system: system))
//            return ref.asAddressable
//        }

//        internal var asAnyKey: AnyDistributedReceptionKey {
//            AnyDistributedReceptionKey(self)
//        }

        public var description: String {
            "DistributedReception.Key<\(String(reflecting: Guest.self))>(id: \(id))"
        }
    }
}
