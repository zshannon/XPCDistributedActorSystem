import Distributed
import XPC
import Testing
@testable import XPCDistributedActorSystem

distributed actor Calculator {
    typealias ActorSystem = XPCDistributedActorSystem

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    distributed func add(_ value1: Int, _ value2: Int) -> Int {
        value1 + value2
    }

    distributed func multiply(_ value1: Int, _ value2: Int) -> Int {
        value1 * value2
    }

    // want to test that the actor ID is shared across the system
    distributed func myId() -> ActorSystem.ActorID {
        id
    }
}

@Suite("XPCDistributedActorSystem Tests")
struct XPCDistributedActorSystemTests {
    @Test("Basic XPC using resolve()")
    func basicXPCTest() async throws {
        let listenerXPC = try XPCListener(type: .anonymous, codeSigningRequirement: nil, incomingSessionHandler: { _ in })
        try await confirmation("creates remote actor just once") { confirmCreatesActor in
            let xpcHostDAS = try await XPCDistributedActorServer(
                listener: listenerXPC,
                actorCreationHandler: { system in
                    // Create a Calculator actor when one isn't found for the given ID
                    confirmCreatesActor()
                    return Calculator(actorSystem: system)
                },
            )

            // Create a client actor system that connects to the listener's endpoint
            let clientDAS = try await XPCDistributedActorClient(
                connectionType: .endpoint(listenerXPC.endpoint),
                codeSigningRequirement: nil
            )

            // For now, let's create a remote reference manually since resolve might return nil for remote actors
            // We'll use the distributed actor initializer that takes an ID and system
            let calculator = try Calculator.resolve(id: .init(), using: clientDAS)
            await #expect(try calculator.id == calculator.myId())

            // Now test actual XPC communication by calling methods on the resolved actor
            // These calls should go through XPC since the actor is in a different system
            let result1 = try await calculator.add(10, 20)
            #expect(result1 == 30)

            let result2 = try await calculator.multiply(5, 6)
            #expect(result2 == 30)
        }
    }

    @Test("Multiple parallel clients")
    func multipleClients() async throws {
        let listenerXPC = try XPCListener(type: .anonymous, codeSigningRequirement: nil, incomingSessionHandler: { _ in })
        let endpoint = listenerXPC.endpoint
        let count: Int = .random(in: 5 ... 10)
        try await confirmation("creates remote actor just once", expectedCount: count) { confirmCreatesActor in
            let xpcHostDAS = try await XPCDistributedActorServer(
                listener: listenerXPC,
                actorCreationHandler: { system in
                    // Create a Calculator actor when one isn't found for the given ID
                    confirmCreatesActor()
                    return Calculator(actorSystem: system)
                },
            )

            let ids = try await withThrowingTaskGroup(of: XPCDistributedActorSystem.ActorID.self) { group in
                for _ in 0 ..< count {
                    group.addTask {
                        let clientDAS = try await XPCDistributedActorClient(
                            connectionType: .endpoint(endpoint),
                            codeSigningRequirement: nil,
                        )

                        // For now, let's create a remote reference manually since resolve might return nil for remote
                        // actors
                        // We'll use the distributed actor initializer that takes an ID and system
                        let calculator = try Calculator.resolve(id: .init(), using: clientDAS)
                        await #expect(try calculator.id == calculator.myId())

                        // Now test actual XPC communication by calling methods on the resolved actor
                        // These calls should go through XPC since the actor is in a different system
                        let result1 = try await calculator.add(10, 20)
                        #expect(result1 == 30)

                        let result2 = try await calculator.multiply(5, 6)
                        #expect(result2 == 30)
                        return calculator.id
                    }
                }
                var ids = Set<XPCDistributedActorSystem.ActorID>()
                for try await id in group {
                    ids.insert(id)
                }
                return ids
            }

            #expect(ids.count == count)
        }
    }
}
