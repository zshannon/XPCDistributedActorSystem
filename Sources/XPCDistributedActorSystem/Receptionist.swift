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
    private var guests: [Key: [ActorSystem.ActorID]] = [:]

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
                await local.removeActorId(id)
            }
        }
    }

    distributed func resignID(_ id: ActorSystem.ActorID) async throws {
        await whenLocal { local in
            await local.removeActorId(id)
        }
    }
    
    private func removeActorId(_ id: ActorSystem.ActorID) async {
        await whenLocal { local in
            _ = local.actors.removeValue(forKey: id)
            for (key, ids) in local.guests {
                local.guests[key] = ids.filter { $0 != id }
                if local.guests[key]?.isEmpty == true {
                    local.guests.removeValue(forKey: key)
                }
            }
        }
    }

    distributed func checkIn<Actor>(_ actor: Actor, key: Key) async throws where Actor: DistributedActor,
        Actor: Codable,
        Actor.ID == ActorSystem.ActorID
    {
        await whenLocal { [id = actor.id] local in
            @Dependency(\.connection) var connection
            local.actors[id] = connection
            local.guests[key] = local.guests[key, default: []] + [id]
        }
    }

    nonisolated func listing<Actor>(of type: Actor.Type, key: Key) async throws -> [Actor]
        where Actor: DistributedActor,
        Actor: Codable, Actor.ActorSystem == ActorSystem, Actor.ID == ActorSystem.ActorID
    {
        let ids = try await actorIds(for: key)
        return try await withThrowingTaskGroup(of: Actor.self) { group in
            for id in ids {
                group.addTask {
                    guard let actor = try? type.resolve(id: id, using: self.actorSystem) else {
                        throw Error.missingConnection
                    }
                    return actor
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }

    private distributed func actorIds(for key: Key) async -> [ActorSystem.ActorID] {
        await whenLocal { local in
            local.guests[key, default: []]
        } ?? []
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
    
    distributed func guestsCount() -> Int {
        guests.count
    }
}
