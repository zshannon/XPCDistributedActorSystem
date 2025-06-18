import Dependencies
import Distributed
import Foundation
import Semaphore
import SwiftyXPC
import Testing

@testable import XPCDistributedActorSystem



@Suite("Receptionist Tests")
struct ReceptionistTests {
    @Test("Basic checkIn test")
    func basicCheckIn() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor zero times", expectedCount: 0) { confirmCreatesActor in
                let host = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { _ in
                        confirmCreatesActor()
                        return nil
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                let publishingClient = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )
                #expect(host.receptionist.id == publishingClient.receptionist.id)
                let secret = UUID().uuidString
                let helloWorldSayer = HelloWorldSayer(secret: secret, actorSystem: publishingClient)
                let key = "hello"
                try await publishingClient.receptionist.checkIn(helloWorldSayer, with: key)

                try await #expect(host.receptionist.count() == 1)
                
                let consumingClient = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )
                #expect(host.receptionist.id == consumingClient.receptionist.id)
                try await #expect(consumingClient.receptionist.count() == 1)
////                let guest: HelloWorldSayer? = consumingClient.receptionist.listing(id: helloWorldSayer.id)
                let guest: HelloWorldSayer? = try? HelloWorldSayer.resolve(id: helloWorldSayer.id, using: consumingClient)
                #expect(guest != nil)
                let response = try await guest!.sayHello()
                #expect(response == "Hello, world! (\(secret))")
//
                try await consumingClient.shutdown()
                try await publishingClient.shutdown()
                try await host.wantsShutdown()
            }
        }
    }
}
