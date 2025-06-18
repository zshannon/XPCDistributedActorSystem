//
//  Receptionist.swift
//  XPCDistributedActorSystem
//
//  Created by Zane Shannon on 6/16/25.
//

import Dependencies
import Distributed
import SwiftyXPC

distributed actor Receptionist {
    typealias ActorSystem = XPCDistributedActorSystem
    typealias Guestable = Codable & DistributedActor
    typealias Key = String

    enum Error: Swift.Error {
        case missingConnection
    }

    static let GlobalID: TypedUUID = .init(type: Receptionist.self, uuid: "Receptionist")

    private var actors: [ActorSystem.ActorID: SwiftyXPC.XPCConnection] = [:]

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
            for (id, _) in local.actors.filter({ $0.value == connection }) {
                local.actors.removeValue(forKey: id)
            }
        }
    }

    distributed func resignID(_ id: ActorSystem.ActorID) async throws {
        await whenLocal { local in
            _ = local.actors.removeValue(forKey: id)
        }
    }

    /// NB: always called "locally" from the actor system host
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

    /// NB: always called "locally" from the actor system host
    nonisolated func connectionForId(
        _ id: ActorSystem.ActorID
    ) async -> XPCConnection? {
        try? await whenLocal { local in
            guard let connection = local.actors[id] else {
                throw Error.missingConnection
            }
            return connection
        }
    }

    distributed func actorsCount() -> Int {
        actors.count
    }
}
