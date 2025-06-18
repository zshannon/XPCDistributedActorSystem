import Dependencies
import Distributed
import Semaphore
import SwiftyXPC
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

    distributed func addStream(_ a: Int, _ b: Int) -> AsyncStream<Int> {
        .init { continuation in
            let goal = a + b
            for i in a ... goal {
                continuation.yield(i)
            }
            continuation.finish()
        }
    }

    distributed func subtractStream(_ stream: AsyncStream<Int>) async -> Int? {
        var output: Int?
        for await value in stream {
            if output == nil {
                output = value
            } else {
                output! -= value
            }
        }
        return output
    }

    distributed func multiply(_ value1: Int, _ value2: Int) -> Int {
        value1 * value2
    }

    // want to test that the actor ID is shared across the system
    distributed func myId() -> ActorSystem.ActorID {
        id
    }

    distributed func addThrowingStream(_ a: Int, _ b: Int) -> AsyncThrowingStream<Int, Error> {
        .init { continuation in
            let goal = a + b
            for i in a ... goal {
                if i == goal - 1 {
                    // Throw an error near the end to test error handling
                    continuation.finish(
                        throwing: CalculatorError.testError("Stream error at value \(i)"),
                    )
                    return
                }
                continuation.yield(i)
            }
            continuation.finish()
        }
    }

    distributed func subtractThrowingStream(_ stream: AsyncThrowingStream<Int, Error>) async throws
        -> Int?
    {
        var output: Int?
        do {
            for try await value in stream {
                if output == nil {
                    output = value
                } else {
                    output! -= value
                }
            }
        } catch {
            throw error
        }
        return output
    }
}

enum CalculatorError: Error, Equatable, Codable {
    case testError(String)
    case invalidInput

    var localizedDescription: String {
        switch self {
        case .invalidInput: "Invalid input provided to Calculator"
        case let .testError(message):
            "Calculator test error: \(message)"
        }
    }
}

@Suite("XPCDistributedActorSystem Tests")
struct XPCDistributedActorSystemTests {
    @Test("[server] basic")
    func basicXPCTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once") { confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                await #expect(try calculator.id == calculator.myId())

                // Now test actual XPC communication by calling methods on the resolved actor
                // These calls should go through XPC since the actor is in a different system
                let result1 = try await calculator.add(10, 20)
                #expect(result1 == 30)

                let result2 = try await calculator.multiply(5, 6)
                #expect(result2 == 30)
                try await clientDAS.shutdown()
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[server] AsyncStream output")
    func xpcAsyncStreamOutputTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once") { confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                await #expect(try calculator.id == calculator.myId())

                let a: Int = .random(in: 10 ... 100)
                let b: Int = .random(in: 10 ... 100)
                let goal = a + b
                try await confirmation("receives all values from addStream", expectedCount: b + 1) {
                    confirmAddStream in
                    var result1 = 0
                    for await value in try await calculator.addStream(a, b) {
                        result1 = value
                        confirmAddStream()
                    }
                    #expect(result1 == goal)
                }
                try await clientDAS.shutdown()
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[server] AsyncStream input")
    func xpcAsyncStreamInputTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once") { confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                //                await #expect(try calculator.id == calculator.myId())

                let a: Int = .random(in: 10 ... 100)
                try await confirmation("consumes input stream") {
                    confirmConsumeStream in
                    do {
                        let result = try await calculator.subtractStream(
                            .init { c in
                                confirmConsumeStream()
                                c.yield(a)
                                c.yield(a)
                                c.finish()
                            },
                        )
                        #expect(result == 0)
                    } catch {
                        throw error
                    }
                }
                try await clientDAS.shutdown()
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[server] AsyncStream input early cancellation")
    func xpcAsyncStreamInputEarlyCancellationTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 1 ... 2) {
                confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                await #expect(try calculator.id == calculator.myId())

                let a: Int = .random(in: 10 ... 100)
                await #expect(
                    throws: SwiftyXPC.XPCError.connectionInvalid,
                    performing: {
                        try await confirmation("consumes input stream") {
                            confirmConsumeStream in
                            do {
                                let semaphore: AsyncSemaphore = .init(value: 0)
                                async let result = try calculator.subtractStream(
                                    .init { c in
                                        confirmConsumeStream()
                                        c.yield(a)
                                        semaphore.signal()
                                    },
                                )
                                try await semaphore.waitUnlessCancelled()
                                try await Task.sleep(for: .milliseconds(10)) // give the xpc message a chance to be sent
                                try await clientDAS.shutdown()
                                _ = try await result // this should throw
                            } catch {
                                throw error
                            }
                        }
                    },
                )
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[server] AsyncStream output early cancellation")
    func xpcAsyncStreamEarlyCancellationTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 1 ... 2) {
                confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                await #expect(try calculator.id == calculator.myId())

                let a = 35
                let b = 51
                let cancelAfter: Int = .random(in: 3 ... (b - a - 2))
                try await confirmation(
                    "receives all values from addStream", expectedCount: cancelAfter,
                ) {
                    confirmAddStream in
                    var result1 = 0
                    var i = 0
                    for await value in try await calculator.addStream(a, b) {
                        i += 1
                        result1 = value
                        confirmAddStream()
                        if i == cancelAfter {
                            break
                        }
                    }
                    #expect(result1 == a + cancelAfter - 1)
                }
                try await clientDAS.shutdown()
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[server] AsyncThrowingStream error handling")
    func xpcAsyncThrowingStreamErrorTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once") { confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                await #expect(try calculator.id == calculator.myId())

                let a: Int = .random(in: 10 ... 100)
                let b: Int = .random(in: 10 ... 100)

                // Test that errors from AsyncThrowingStream are properly propagated
                await #expect(throws: (any Error).self) {
                    let throwingStream = try await calculator.addThrowingStream(a, b)
                    _ = try await calculator.subtractThrowingStream(throwingStream)
                }

                try await clientDAS.shutdown()
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[server] AsyncThrowingStream input error handling")
    func xpcAsyncThrowingStreamInputErrorTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once") { confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                await #expect(try calculator.id == calculator.myId())

                let a: Int = .random(in: 10 ... 100)

                // Test error propagation from input AsyncThrowingStream
                await #expect(throws: (any Error).self) {
                    try await calculator.subtractThrowingStream(
                        .init { continuation in
                            continuation.yield(a)
                            continuation.yield(a)
                            continuation.finish(
                                throwing: CalculatorError.testError("Input stream error"),
                            )
                        },
                    )
                }

                try await clientDAS.shutdown()
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[server] AsyncThrowingStream early cancellation")
    func xpcAsyncThrowingStreamEarlyCancellationTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown") { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 1 ... 2) {
                confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                // Create a client actor system that connects to the listener's endpoint
                let clientDAS = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                let calculator = try Calculator.resolve(
                    id: .init(Calculator.self), using: clientDAS,
                )
                await #expect(try calculator.id == calculator.myId())

                let a: Int = .random(in: 10 ... 100)
                await #expect(
                    throws: SwiftyXPC.XPCError.connectionInvalid,
                    performing: {
                        try await confirmation("consumes throwing input stream") {
                            confirmConsumeStream in
                            do {
                                let semaphore: AsyncSemaphore = .init(value: 0)
                                async let result = try calculator.subtractThrowingStream(
                                    .init { c in
                                        confirmConsumeStream()
                                        c.yield(a)
                                        semaphore.signal()
                                    },
                                )
                                try await semaphore.waitUnlessCancelled()
                                try await Task.sleep(for: .milliseconds(10)) // give the xpc message a chance to be sent
                                try await clientDAS.shutdown()
                                _ = try await result // this should throw
                            } catch {
                                throw error
                            }
                        }
                    },
                )
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    @Test("[client] basic")
    func clientHostedDATest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
            confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 0) {
                confirmCreatesActor in
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

                // Create a client actor system that connects to the listener's endpoint
                let client = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                do {
                    let localCalculator = Calculator(actorSystem: client)

                    try await client.receptionist.actorReady(localCalculator.id)
                    let remoteCalculator = try Calculator.resolve(
                        id: localCalculator.id, using: host,
                    )

                    await #expect(try localCalculator.id == localCalculator.myId())
                    await #expect(try remoteCalculator.id == remoteCalculator.myId())
                    await #expect(try localCalculator.myId() == remoteCalculator.myId())

                    let result1 = try await localCalculator.add(10, 20)
                    #expect(result1 == 30)

                    // Now test actual XPC communication by calling methods on the resolved actor
                    // These calls should go through XPC since the actor is in a different system
                    let result2 = try await remoteCalculator.multiply(5, 6)
                    #expect(result2 == 30)
                }

                try await client.shutdown()
                let count = try await host.receptionist.actorsCount()
                #expect(
                    count == 0,
                    "Expected no actors to be registered in the receptionist after shutdown",
                )
                try await host.wantsShutdown()
            }
        }
    }

    @Test("[client] AsyncStream output")
    func clientHostedDAAsyncStreamOutputTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
            confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 0) {
                confirmCreatesActor in
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

                // Create a client actor system that connects to the listener's endpoint
                let client = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                // For now, let's create a remote reference manually since resolve might return nil for remote actors
                // We'll use the distributed actor initializer that takes an ID and system
                do {
                    let localCalculator = Calculator(actorSystem: client)
                    try await client.receptionist.actorReady(localCalculator.id)
                    let remoteCalculator = try Calculator.resolve(
                        id: localCalculator.id, using: host,
                    )

                    let a: Int = .random(in: 10 ... 100)
                    let b: Int = .random(in: 10 ... 100)
                    let goal = a + b
                    try await confirmation(
                        "receives all values from addStream", expectedCount: b + 1,
                    ) {
                        confirmAddStream in
                        var result1 = 0
                        for await value in try await remoteCalculator.addStream(a, b) {
                            result1 = value
                            confirmAddStream()
                        }
                        #expect(result1 == goal)
                    }
                }

                try await client.shutdown()
                let count = try await host.receptionist.actorsCount()
                #expect(
                    count == 0,
                    "Expected no actors to be registered in the receptionist after shutdown",
                )
                try await host.wantsShutdown()
            }
        }
    }

    @Test("[client] AsyncStream input")
    func clientHostedDAAsyncStreamInputTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
            confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 0) {
                confirmCreatesActor in
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

                // Create a client actor system that connects to the listener's endpoint
                let client = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                let localCalculator = Calculator(actorSystem: client)
                try await client.receptionist.actorReady(localCalculator.id)
                let remoteCalculator = try Calculator.resolve(id: localCalculator.id, using: host)

                let a: Int = .random(in: 10 ... 100)
                try await confirmation("consumes input stream") {
                    confirmConsumeStream in
                    do {
                        let result = try await remoteCalculator.subtractStream(
                            .init { c in
                                confirmConsumeStream()
                                c.yield(a)
                                c.yield(a)
                                c.finish()
                            },
                        )
                        #expect(result == 0)
                    } catch {
                        throw error
                    }
                }

                try await client.shutdown()
                let count = try await host.receptionist.actorsCount()
                #expect(
                    count == 0,
                    "Expected no actors to be registered in the receptionist after shutdown",
                )
                try await host.wantsShutdown()
            }
        }
    }

    @Test("[client] AsyncStream input early cancellation")
    func clientHostedDAAsyncStreamInputEarlyCancellationTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
            confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 0) {
                confirmCreatesActor in
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

                // Create a client actor system that connects to the listener's endpoint
                let client = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                let localCalculator = Calculator(actorSystem: client)
                try await client.receptionist.actorReady(localCalculator.id)
                let remoteCalculator = try Calculator.resolve(id: localCalculator.id, using: host)

                let a: Int = .random(in: 10 ... 100)
                await #expect(
                    throws: SwiftyXPC.XPCError.connectionInvalid,
                    performing: {
                        try await confirmation("consumes input stream") {
                            confirmConsumeStream in
                            do {
                                let semaphore: AsyncSemaphore = .init(value: 0)
                                async let result = try remoteCalculator.subtractStream(
                                    .init { c in
                                        confirmConsumeStream()
                                        c.yield(a)
                                        semaphore.signal()
                                    },
                                )
                                try await semaphore.waitUnlessCancelled()
                                try await Task.sleep(for: .milliseconds(10)) // give the xpc message a chance to be sent
                                try await client.shutdown()
                                _ = try await result // this should throw
                            } catch {
                                throw error
                            }
                        }
                    },
                )
                try await host.wantsShutdown()
            }
        }
    }

    @Test("[client] AsyncStream output early cancellation")
    func clientHostedDAAsyncStreamOutputEarlyCancellationTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
            confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 0) {
                confirmCreatesActor in
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

                // Create a client actor system that connects to the listener's endpoint
                let client = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                let localCalculator = Calculator(actorSystem: client)
                try await client.receptionist.actorReady(localCalculator.id)
                let remoteCalculator = try Calculator.resolve(id: localCalculator.id, using: host)

                let a: Int = .random(in: 10 ... 100)
                let b: Int = .random(in: 10 ... 100)

                //                await #expect(
                //                    throws: SwiftyXPC.XPCError.connectionInvalid,
                //                    performing: {
                let semaphore: AsyncSemaphore = .init(value: 0)
                var counter = 0
                async let task: () = {
                    do {
                        for try await _ in try await remoteCalculator.addStream(a, b) {
                            counter += 1
                            if counter == 1 {
                                semaphore.signal()
                            }
                        }
                    } catch {
                        // Expected to throw
                    }
                }()
                try await semaphore.waitUnlessCancelled()
                try await Task.sleep(for: .milliseconds(10)) // give the xpc message a chance to be sent
                try await client.shutdown()
                try await task // this should complete with an error
                //                    },
                //                )
                try await host.wantsShutdown()
            }
        }
    }

    @Test("[client] AsyncThrowingStream error handling")
    func clientHostedDAAsyncThrowingStreamErrorTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
            confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 0) {
                confirmCreatesActor in
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

                // Create a client actor system that connects to the listener's endpoint
                let client = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                let localCalculator = Calculator(actorSystem: client)
                try await client.receptionist.actorReady(localCalculator.id)
                let remoteCalculator = try Calculator.resolve(id: localCalculator.id, using: host)

                let a: Int = .random(in: 10 ... 100)
                let b: Int = .random(in: 10 ... 100)

                // Test that errors from AsyncThrowingStream are properly propagated
                await #expect(throws: (any Error).self) {
                    let throwingStream = try await remoteCalculator.addThrowingStream(a, b)
                    _ = try await remoteCalculator.subtractThrowingStream(throwingStream)
                }

                try await client.shutdown()
                let count = try await host.receptionist.actorsCount()
                #expect(
                    count == 0,
                    "Expected no actors to be registered in the receptionist after shutdown",
                )
                try await host.wantsShutdown()
            }
        }
    }

    @Test("[client] AsyncThrowingStream input error handling")
    func clientHostedDAAsyncThrowingStreamInputErrorTest() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
            confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: 0) {
                confirmCreatesActor in
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

                // Create a client actor system that connects to the listener's endpoint
                let client = try await XPCDistributedActorClient(
                    attemptReconnect: false,
                    connectionType: .endpoint(listenerXPC.endpoint),
                    codeSigningRequirement: nil,
                )

                let localCalculator = Calculator(actorSystem: client)
                try await client.receptionist.actorReady(localCalculator.id)
                let remoteCalculator = try Calculator.resolve(id: localCalculator.id, using: host)

                let a: Int = .random(in: 10 ... 100)

                // Test that errors from input AsyncThrowingStream are properly propagated
                try await confirmation("throws error from input stream") { confirmError in
                    do {
                        _ = try await remoteCalculator.subtractThrowingStream(
                            .init { c in
                                c.yield(a)
                                c.yield(a)
                                c.finish(throwing: CalculatorError.invalidInput)
                            },
                        )
                    } catch {
                        if error is XPCDistributedActorSystem.ProtocolError {
                            confirmError()
                        } else {
                            throw error
                        }
                    }
                }
                try await client.shutdown()
                let count = try await host.receptionist.actorsCount()
                #expect(
                    count == 0,
                    "Expected no actors to be registered in the receptionist after shutdown",
                )
                try await host.wantsShutdown()
            }
        }
    }

    @Test("[client] multiple parallel consumers")
    func multipleClients() async throws {
        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        let endpoint = listenerXPC.endpoint
        let count: Int = .random(in: 5 ... 10)
        try await confirmation(
            "host becomes ready for shutdown",
            expectedCount: 1 ... count,
        ) { confirmReadyForShutdown in
            try await confirmation("creates remote actor just once", expectedCount: count) {
                confirmCreatesActor in
                let xpcHostDAS = try await XPCDistributedActorServer(
                    listener: listenerXPC,
                    actorCreationHandler: { system in
                        // Create a Calculator actor when one isn't found for the given ID
                        confirmCreatesActor()
                        return Calculator(actorSystem: system)
                    },
                ) { event in
                    if case .readyForShutdown = event {
                        confirmReadyForShutdown()
                    }
                }

                let ids = try await withThrowingTaskGroup(
                    of: XPCDistributedActorSystem.ActorID.self,
                ) {
                    group in
                    for _ in 0 ..< count {
                        group.addTask {
                            let clientDAS = try await XPCDistributedActorClient(
                                attemptReconnect: false,
                                connectionType: .endpoint(endpoint),
                                codeSigningRequirement: nil,
                            )

                            // For now, let's create a remote reference manually since resolve might return nil for
                            // remote
                            // actors
                            // We'll use the distributed actor initializer that takes an ID and system
                            let calculator = try Calculator.resolve(
                                id: .init(Calculator.self), using: clientDAS,
                            )
                            await #expect(try calculator.id == calculator.myId())

                            // Now test actual XPC communication by calling methods on the resolved actor
                            // These calls should go through XPC since the actor is in a different system
                            let result1 = try await calculator.add(10, 20)
                            #expect(result1 == 30)

                            let result2 = try await calculator.multiply(5, 6)
                            #expect(result2 == 30)

                            try await clientDAS.shutdown()

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
                try await xpcHostDAS.wantsShutdown()
            }
        }
    }

    //    @Test("Test client hosted distributed actor - AsyncThrowingStream early cancellation")
    //    func clientHostedDAAsyncThrowingStreamEarlyCancellationTest() async throws {
    //        let listenerXPC = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
    //        try await confirmation("host becomes ready for shutdown", expectedCount: 1) {
    //            confirmReadyForShutdown in
    //            try await confirmation("creates remote actor just once", expectedCount: 0) {
    //                confirmCreatesActor in
    //                let host = try await XPCDistributedActorServer(
    //                    listener: listenerXPC,
    //                    actorCreationHandler: { _ in
    //                        confirmCreatesActor()
    //                        return nil
    //                    },
    //                ) { event in
    //                    if case .readyForShutdown = event {
    //                        confirmReadyForShutdown()
    //                    }
    //                }
    //
    //                // Create a client actor system that connects to the listener's endpoint
    //                let client = try await XPCDistributedActorClient(
    //                    attemptReconnect: false,
    //                    connectionType: .endpoint(listenerXPC.endpoint),
    //                    codeSigningRequirement: nil,
    //                )
    //
    //                let localCalculator = Calculator(actorSystem: client)
    //                try await client.receptionist.actorReady(localCalculator.id)
    //                let remoteCalculator = try Calculator.resolve(id: localCalculator.id, using: host)
    //
    //                let a: Int = .random(in: 10 ... 100)
    //                let b: Int = .random(in: 10 ... 100)
    //
    //                await #expect(
    //                    throws: SwiftyXPC.XPCError.connectionInvalid,
    //                    performing: {
    //                        let semaphore: AsyncSemaphore = .init(value: 0)
    //                        var counter = 0
    //                        async let task: () = {
    //                            do {
    //                                for try await _ in try await remoteCalculator.addThrowingStream(
    //                                    a, b
    //                                ) {
    //                                    counter += 1
    //                                    if counter == 1 {
    //                                        semaphore.signal()
    //                                    }
    //                                }
    //                            } catch {
    //                                // Expected to throw
    //                            }
    //                        }()
    //                        try await semaphore.waitUnlessCancelled()
    //                        try await Task.sleep(for: .milliseconds(10)) // give the xpc message a chance to be sent
    //                        try await client.shutdown()
    //                        try await task // this should complete with an error
    //                    },
    //                )
    //                try await host.wantsShutdown()
    //            }
    //        }
    //    }
}

extension SwiftyXPC.XPCError: @retroactive Equatable {
    public static func == (lhs: SwiftyXPC.XPCError, rhs: SwiftyXPC.XPCError) -> Bool {
        switch (lhs, rhs) {
        case (.connectionInterrupted, .connectionInterrupted): true
        case (.connectionInvalid, .connectionInvalid): true
        case (.invalidCodeSignatureRequirement, .invalidCodeSignatureRequirement): true
        case let (.unknown(lhsCode), .unknown(rhsCode)): lhsCode == rhsCode
        case (.terminationImminent, .terminationImminent): true
        default: false
        }
    }
}
