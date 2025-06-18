import Dependencies
import Distributed
import Foundation
import Semaphore
import SwiftyXPC
import Testing

@testable import XPCDistributedActorSystem

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

@Suite("Receptionist Tests")
struct ReceptionistTests {
    @Test("basic clientA->clientB")
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
                try await publishingClient.receptionist.actorReady(helloWorldSayer.id)
                try await #expect(host.receptionist.actorsCount() == 1)

                let consumingClient = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )
                #expect(host.receptionist.id == consumingClient.receptionist.id)
                try await #expect(consumingClient.receptionist.actorsCount() == 1)

                let guest: HelloWorldSayer? = try? HelloWorldSayer.resolve(
                    id: helloWorldSayer.id,
                    using: consumingClient
                )
                #expect(guest != nil)
                let response = try await guest!.sayHello()
                #expect(response == "Hello, world! (\(secret))")

                try await consumingClient.shutdown()
                try await publishingClient.shutdown()
                try await host.wantsShutdown()
            }
        }
    }
}
