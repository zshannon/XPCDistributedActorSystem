import Distributed
import Foundation
import SwiftyXPC
import Testing

@testable import XPCDistributedActorSystem

extension DistributedReception.Key {
    static var helloWorlds: DistributedReception.Key<HelloWorld> {
        "hello-worlds"
    }
}

// MARK: - Tests

struct XPCDistributedReceptionistTests {
    @Test("Distributed Receptionist - Actor Discovery")
    func distributedReceptionistActorDiscovery() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        let endpoint = listenerXPC.endpoint

        try await confirmation("server becomes ready for shutdown") { confirmReadyForShutdown in
//            try await confirmation("first client lookup fails") { confirmFirstLookupFails in
//                try await confirmation("second client checks in actor") { confirmActorCheckedIn in
//                    try await confirmation("first client lookup succeeds after check-in") {
//                        confirmSecondLookupSucceeds in
            // Create the server
            let server = try await XPCDistributedActorServer(
                listener: listenerXPC,
                actorCreationHandler: nil,
            ) { event in
                if case .readyForShutdown = event {
                    confirmReadyForShutdown()
                }
            }

            // Create first client
            let client1 = try await XPCDistributedActorClient(
                attemptReconnect: false,
                connectionType: .endpoint(endpoint),
                codeSigningRequirement: nil,
            )
            print("client1", client1)

            // Create second client
            let client2 = try await XPCDistributedActorClient(
                attemptReconnect: false,
                connectionType: .endpoint(endpoint),
                codeSigningRequirement: nil,
            )
            print("client2", client2)
            
            var helloWorlds = try await client1.receptionist.lookup(.helloWorlds)
            #expect(helloWorlds.isEmpty)
            
            
            print("============   CHECKIN    =============")
            
            
            let hw = HelloWorld(actorSystem: client2)
            try await client2.receptionist.checkIn(hw, with: .helloWorlds)
            
            print("============   LOOKUP    =============")
            helloWorlds = try await client1.receptionist.lookup(.helloWorlds)
            #expect(helloWorlds.count == 1)
            print("============   GREET    =============")
            let response = try await helloWorlds.first?.greet("Tester")
            #expect(response == "Hello, Tester!")
                

//                        // Create HelloWorld actor on server
//                        let helloWorld = HelloWorld(actorSystem: server)
//
//                        // Get server's receptionist
//                        let serverReceptionist = try await server.getReceptionist()
//
//                        // First client attempts to lookup HelloWorld (should be empty)
//                        // Client resolves the server's receptionist
//                        let receptionist1 = try await client1.getReceptionist()
//                        let listing1 = await receptionist1.listing(
//                            of: HelloWorld.self, tag: "hello-world")
//                        var found = false
//                        for try await _ in listing1.prefix(1) {
//                            found = true
//                        }
//                        #expect(!found)
//                        confirmFirstLookupFails()
//
//                        // Check in HelloWorld actor with server's receptionist
//                        serverReceptionist.checkIn(helloWorld, tag: "hello-world")
//                        confirmActorCheckedIn()
//
//                        // Give receptionist time to process the check-in
//                        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
//
//                        // First client attempts to lookup HelloWorld again (should succeed)
//                        let listing2 = await receptionist1.listing(
//                            of: HelloWorld.self, tag: "hello-world")
//                        var discoveredActor: HelloWorld?
//                        for try await actor in listing2.prefix(1) {
//                            discoveredActor = actor
//                        }
//
//                        #expect(discoveredActor != nil)
//
//                        if let discoveredActor {
//                            // Test that we can actually use the discovered actor
//                            let greeting = try await discoveredActor.greet("World")
//                            #expect(greeting == "Hello, World!")
//
//                            // Verify it's the same actor
//                            let originalID = helloWorld.id
//                            let discoveredID = discoveredActor.id
//                            #expect(discoveredID == originalID)
//
//                            confirmSecondLookupSucceeds()
//                        } else {
//                            Issue.record("Failed to find HelloWorld actor after check-in")
//                        }
//
//                        // Cleanup
//                        server.resignID(helloWorld.id)
            try await client1.shutdown()
            try await client2.shutdown()
            try await server.wantsShutdown()
        }
    }
//
//    @Test("Distributed Receptionist - Listing Stream")
//    func distributedReceptionistListingStream() async throws {
//        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
//        let endpoint = listenerXPC.endpoint
//
//        try await confirmation("server becomes ready for shutdown") { confirmReadyForShutdown in
//            try await confirmation("listing receives existing and new actors", expectedCount: 2) {
//                confirmListingReceived in
//                // Create the server
//                let server = try await XPCDistributedActorServer(
//                    listener: listenerXPC,
//                    actorCreationHandler: nil,
//                ) { event in
//                    if case .readyForShutdown = event {
//                        confirmReadyForShutdown()
//                    }
//                }
//
//                // Create clients
//                let client1 = try await XPCDistributedActorClient(
//                    attemptReconnect: false,
//                    connectionType: .endpoint(endpoint),
//                    codeSigningRequirement: nil,
//                )
//
//                let client2 = try await XPCDistributedActorClient(
//                    attemptReconnect: false,
//                    connectionType: .endpoint(endpoint),
//                    codeSigningRequirement: nil,
//                )
//
//                // Wait for systems to be initialized
//                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
//
//                // Get server's receptionist
//                let serverReceptionist = try await server.getReceptionist()
//
//                // Clients will use the server's receptionist
//                let clientReceptionist = try await client1.getReceptionist()
//
//                // Create and check in first actor on server
//                let helloWorld1 = HelloWorld(actorSystem: server)
//                await serverReceptionist.checkIn(helloWorld1, tag: "hello-world")
//
//                // Start listing for HelloWorld actors from client
//                let listing = await clientReceptionist.listing(
//                    of: HelloWorld.self, tag: "hello-world")
//
//                // Create a task to collect actors from the listing
//                let listingTask = Task {
//                    var discoveredActors: [HelloWorld] = []
//                    for try await actor in listing {
//                        discoveredActors.append(actor)
//                        confirmListingReceived()
//
//                        // Stop after receiving 2 actors
//                        if discoveredActors.count >= 2 {
//                            break
//                        }
//                    }
//                    return discoveredActors
//                }
//
//                // Give the listing time to receive the first actor
//                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
//
//                // Create and check in second actor on server
//                let helloWorld2 = HelloWorld(actorSystem: server)
//                await serverReceptionist.checkIn(helloWorld2, tag: "hello-world")
//
//                // Wait for listing to complete
//                let discoveredActors = try await listingTask.value
//
//                // Verify we received both actors
//                #expect(discoveredActors.count == 2)
//
//                // Verify the actors work correctly
//                for (index, actor) in discoveredActors.enumerated() {
//                    let greeting = try await actor.greet("Actor \(index + 1)")
//                    #expect(greeting == "Hello, Actor \(index + 1)!")
//                }
//
//                // Cleanup
//                listingTask.cancel()
//                server.resignID(helloWorld1.id)
//                server.resignID(helloWorld2.id)
//                try await client1.shutdown()
//                try await client2.shutdown()
//                try await server.wantsShutdown()
//            }
//        }
//    }
//
//    @Test("Distributed Receptionist - Multiple Keys")
//    func distributedReceptionistMultipleKeys() async throws {
//        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
//        let endpoint = listenerXPC.endpoint
//
//        try await confirmation("server becomes ready for shutdown") { confirmReadyForShutdown in
//            // Create the server
//            let server = try await XPCDistributedActorServer(
//                listener: listenerXPC,
//                actorCreationHandler: nil,
//            ) { event in
//                if case .readyForShutdown = event {
//                    confirmReadyForShutdown()
//                }
//            }
//
//            // Create client
//            let client = try await XPCDistributedActorClient(
//                attemptReconnect: false,
//                connectionType: .endpoint(endpoint),
//                codeSigningRequirement: nil,
//            )
//
//            // Wait for systems to be initialized
//            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
//
//            // Get server's receptionist
//            let serverReceptionist = try await server.getReceptionist()
//
//            // Client will query the server's receptionist
//            let clientReceptionist = try await client.getReceptionist()
//
//            // Create two HelloWorld actors on server
//            let helloWorld1 = HelloWorld(actorSystem: server)
//            let helloWorld2 = HelloWorld(actorSystem: server)
//
//            // Check them in with different tags using server's receptionist
//            await serverReceptionist.checkIn(helloWorld1, tag: "hello-world-service")
//            await serverReceptionist.checkIn(helloWorld2, tag: "alternate-hello-world")
//
//            // Give receptionist time to process
//            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
//
//            // Lookup actors with different tags using client's view of receptionist
//            let mainListing = await clientReceptionist.listing(
//                of: HelloWorld.self, tag: "hello-world-service")
//            let altListing = await clientReceptionist.listing(
//                of: HelloWorld.self, tag: "alternate-hello-world")
//
//            var mainActors: [HelloWorld] = []
//            var altActors: [HelloWorld] = []
//
//            for try await actor in mainListing.prefix(1) {
//                mainActors.append(actor)
//            }
//
//            for try await actor in altListing.prefix(1) {
//                altActors.append(actor)
//            }
//
//            // Verify each tag has exactly one actor
//            #expect(mainActors.count == 1)
//            #expect(altActors.count == 1)
//
//            // Verify they are different actors
//            if let main = mainActors.first, let alt = altActors.first {
//                #expect(main.id != alt.id)
//            }
//
//            // Cleanup
//            server.resignID(helloWorld1.id)
//            server.resignID(helloWorld2.id)
//            try await client.shutdown()
//            try await server.wantsShutdown()
//        }
//    }
}
