import Dependencies
import Distributed
import Foundation

final class AsyncIteratorWrapper<Element>: @unchecked Sendable where Element: Codable & Sendable {
    private let id: XPCDistributedActorSystem.ActorID
    private var iterator: AsyncStream<Element>.AsyncIterator?

    init(
        id: XPCDistributedActorSystem.ActorID,
        iterator: AsyncStream<Element>.AsyncIterator
    ) {
        self.id = id
        self.iterator = iterator
    }

    func next() async -> Element? {
        guard var iterator else { return nil }
        guard let next = await iterator.next() else {
            @Dependency(\.distributedActorSystem) var das
            await das?.releaseCodableAsyncStream(id)
            return nil
        }
        return next
    }

    deinit {
        Task { [id] in
            @Dependency(\.distributedActorSystem) var das
            await das?.releaseCodableAsyncStream(id)
        }
    }
}

distributed actor CodableAsyncStream<Element> where Element: Codable & Sendable {
    typealias ActorSystem = XPCDistributedActorSystem

    var iterator: AsyncIteratorWrapper<Element>?

    enum Error: Swift.Error {
        case actorSystemUnavailable, exhausted
    }

    distributed func next() async throws -> Element? {
        do {
            return try await whenLocal { local in
                guard let iterator = local.iterator else { throw Error.exhausted }
                guard let next = await iterator.next() else { throw Error.exhausted }

                return next
            }
        } catch {
            if case CodableAsyncStream.Error.exhausted = error {
                return nil
            } else {
                throw error
            }
        }
    }

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    nonisolated func store(stream: AsyncStream<Element>) {
        Task {
            await whenLocal { local in
                await local.store(stream: stream)
                @Dependency(\.distributedActorSystem) var das
                await das?.storeCodableAsyncStream(local)
                @Dependency(\.dasAsyncStreamCodableSemaphore) var semaphore
                semaphore.signal()
            }
        }
    }

    func store(stream: AsyncStream<Element>) async {
        iterator = AsyncIteratorWrapper<Element>(id: id, iterator: stream.makeAsyncIterator())
    }
}

extension AsyncStream: Codable where Element: Codable {
    enum CodingKeys: CodingKey {
        case actorID
    }

    public init(from decoder: Decoder) throws where Element: Sendable {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(XPCDistributedActorSystem.ActorID.self)
        self.init(Element.self, bufferingPolicy: .bufferingNewest(128)) { continuation in
            let forwardingTask = Task {
                @Dependency(\.dasAsyncStreamCodableSemaphore) var semaphore
                @Dependency(\.distributedActorSystem) var das
                guard let das else { throw CodableAsyncStream<Element>.Error.actorSystemUnavailable }
                let stream = try CodableAsyncStream<Element>.resolve(id: id, using: das)
                semaphore.signal()
                await withTaskCancellationHandler {
                    do {
                        while let element = try await stream.next() {
                            continuation.yield(element)
                        }
                    } catch {
                        // continuation.finish(throwing: error)
                    }
                    continuation.finish()
                } onCancel: {
                    Task {
                        await das.releaseCodableAsyncStream(id)
                    }
                }
            }
            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }

    public func encode(to encoder: Encoder) throws where Element: Sendable {
        @Dependency(\.distributedActorSystem) var das
        guard let das else { throw CodableAsyncStream<Element>.Error.actorSystemUnavailable }
        let cas = CodableAsyncStream<Element>(actorSystem: das)
        cas.store(stream: self)
        var container = encoder.singleValueContainer()
        try container.encode(cas.id)
    }
}

// this is a funny hack to make it possible to decode AsyncStream<any Codable> asynchronously
protocol _IsAsyncStreamOfCodable {}
extension AsyncStream: _IsAsyncStreamOfCodable where Element: Codable {}
extension AsyncStream: Sendable where Element: Sendable {}

/// Type‑erased box that keeps any `CodableAsyncStream` alive
/// while exposing only its `id`.  Needed so we can store streams
/// with heterogeneous `Element` types in the same collection.
private struct AnyCodableAsyncStream: @unchecked Sendable {
    let id: XPCDistributedActorSystem.ActorID
    private let _boxed: Any // strong reference keeps the actor alive

    init<E: Codable & Sendable>(_ base: CodableAsyncStream<E>) {
        id = base.id
        _boxed = base
    }
}

/// Manages a *heterogeneous* set of `CodableAsyncStream`s.
/// Each stored stream can have a different `Element` type.
actor CodableAsyncStreamManager {
    private var storage: [AnyCodableAsyncStream] = []

    /// Store a new stream (any element type) so that it stays alive.
    func storeCodableAsyncStream<E: Codable & Sendable>(_ cas: CodableAsyncStream<E>) async {
        storage.append(AnyCodableAsyncStream(cas))
    }

    /// Release a previously‑stored stream once its remote side finishes.
    func releaseCodableAsyncStream(_ id: XPCDistributedActorSystem.ActorID) async {
        storage.removeAll { $0.id == id }
    }

    /// Useful for diagnostics & testing.
    func countCodableAsyncStreams() async -> Int {
        storage.count
    }
}
