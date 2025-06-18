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

    distributed func sayHelloStream() -> AsyncStream<String> {
        .init { continuation in
            continuation.yield("Hello,")
            continuation.yield("world!")
            continuation.yield("(\(secret))")
            continuation.finish()
        }
    }

    distributed func sayHelloStreamInput(stream: AsyncStream<String>) async -> String {
        var response: [String] = []
        for await word in stream {
            response.append(word)
        }
        return response.joined(separator: " ")
    }
}

@Suite("Receptionist Tests")
struct ReceptionistTests {
    @Test("basic clientA->clientB")
    func basicClientToClientTest() async throws {
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
                    using: consumingClient,
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

    @Test("AsyncStream output clientA->clientB")
    func basicClientToClientAsyncStreamOutputTest() async throws {
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
                    using: consumingClient,
                )
                #expect(guest != nil)
                var response: [String] = []
                for await word in try await guest!.sayHelloStream() {
                    response += [word]
                }
                #expect(response.joined(separator: " ") == "Hello, world! (\(secret))")

                try await consumingClient.shutdown()
                try await publishingClient.shutdown()
                try await host.wantsShutdown()
            }
        }
    }

    @Test("AsyncStream input clientA->clientB")
    func basicClientToClientAsyncStreamInputTest() async throws {
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
                    using: consumingClient,
                )
                #expect(guest != nil)

                let response = try await guest!.sayHelloStreamInput(stream: .init { continuation in
                    continuation.yield("Hello,")
                    continuation.yield("world!")
                    continuation.yield("(\(secret))")
                    continuation.finish()
                })

                #expect(response == "Hello, world! (\(secret))")

                try await consumingClient.shutdown()
                try await publishingClient.shutdown()
                try await host.wantsShutdown()
            }
        }
    }

    @Test("basic guest")
    func basicGuestTest() async throws {
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

                let key = "hello"
                let secret = UUID().uuidString
                let publishingClient = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                do {
                    #expect(host.receptionist.id == publishingClient.receptionist.id)

                    let helloWorldSayer = HelloWorldSayer(secret: secret, actorSystem: publishingClient)

                    try await publishingClient.receptionist.checkIn(helloWorldSayer, key: key)
                    try await #expect(host.receptionist.actorsCount() == 1)
                }

                do {
                    let consumingClient = try await XPCDistributedActorClient(
                        attemptReconnect: false,
                        connectionType: .endpoint(listenerXPC.endpoint),
                        codeSigningRequirement: nil,
                    )
                    #expect(host.receptionist.id == consumingClient.receptionist.id)
                    try await #expect(consumingClient.receptionist.actorsCount() == 1)

                    let guests = try await consumingClient.receptionist.listing(
                        of: HelloWorldSayer.self,
                        key: key,
                    )
                    #expect(guests.count == 1)

                    let response = try await guests.first?.sayHello()
                    #expect(response == "Hello, world! (\(secret))")
                    try await consumingClient.shutdown()
                }

                try await publishingClient.shutdown()
                try await #expect(host.receptionist.actorsCount() == 0)
                try await #expect(host.receptionist.guestsCount() == 0)
                try await host.wantsShutdown()
            }
        }
    }
}
