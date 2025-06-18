//
//  Receptionist.swift
//  XPCDistributedActorSystem
//
//  Created by Zane Shannon on 6/16/25.
//

import Dependencies
import Distributed
import SwiftyXPC

distributed actor HelloWorldSayer {
    typealias ActorSystem = XPCDistributedActorSystem

    let secret: String

    init(secret: String, actorSystem: XPCDistributedActorSystem) {
        self.secret = secret
        self.actorSystem = actorSystem
    }

    distributed func sayHello() -> String {
        "Hello, world! (\(secret))"
    }
}

distributed actor Receptionist {
    typealias ActorSystem = XPCDistributedActorSystem
    typealias Guestable = Codable & DistributedActor
    typealias Key = String

    enum Error: Swift.Error {
        case missingConnection
    }

    static let GlobalID: TypedUUID = .init(type: Receptionist.self, uuid: "Receptionist")

    var actors: [ActorSystem.ActorID: SwiftyXPC.XPCConnection] = [:]
    private var guests: [Key: any Guestable] = [:]

    static func resolve(actorSystem: ActorSystem) throws -> Receptionist {
        return try resolve(id: GlobalID, using: actorSystem)
    }

    distributed func actorReady(_ id: ActorSystem.ActorID) async throws {
        await whenLocal { local in
            @Dependency(\.connection) var connection
            local.actors[id] = connection
        }
    }
    
    distributed func shutdown() async throws {
        await whenLocal { local in
            @Dependency(\.connection) var connection
            local.actors.filter({ $0.value == connection }).forEach { id, _ in
                local.actors.removeValue(forKey: id)
            }
        }
    }
    
    distributed func resignID(_ id: ActorSystem.ActorID) async throws {
        await whenLocal { local in
            _ = local.actors.removeValue(forKey: id)
        }
    }

    nonisolated func connectionFor<Act>(
        _ actor: Act
    ) async -> XPCConnection? where Act: DistributedActor, Act.ID == ActorSystem.ActorID {
        try? await whenLocal { local in
            guard let connection = local.actors[actor.id] else {
                throw Error.missingConnection
            }
            return connection
        }
    }

    distributed func checkIn<Guest>(
        _ guest: Guest,
        with key: Key
    ) async where Guest: DistributedActor, Guest: Codable, Guest.ActorSystem == ActorSystem {
        await whenLocal { local in
            local.localCheckIn(guest, key: key)
        }
    }

    distributed func count() -> Int {
        guests.count
    }

    nonisolated func listing<Guest>(
        id: ActorSystem.ActorID
    ) -> Guest? where Guest: DistributedActor, Guest: Codable, Guest.ActorSystem == ActorSystem {
        try? Guest.resolve(id: id, using: actorSystem)
    }

    private func localCheckIn<Guest>(_ guest: Guest, key: Key) where Guest: DistributedActor, Guest: Codable,
        Guest.ActorSystem == ActorSystem
    {
        guests[key] = guest
    }
}
