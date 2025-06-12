import Dependencies
import Distributed
import Foundation
import Semaphore

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
//            @Dependency(\.actorSystem) var actorSystem
//            await actorSystem?.releaseCodableAsyncStream(id)
            return nil
        }
        return next
    }

//    deinit {
//        Task { [id] in
//            @Dependency(\.actorSystem) var actorSystem
//            await actorSystem?.releaseCodableAsyncStream(id)
//        }
//    }
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
//                @Dependency(\.actorSystem) var actorSystem
//                await actorSystem?.storeCodableAsyncStream(local)
                @Dependency(\.casSemaphore) var semaphore
                semaphore?.signal()
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
                @Dependency(\.casSemaphore) var semaphore
                @Dependency(\.actorSystem) var actorSystem
                guard let actorSystem else { throw CodableAsyncStream<Element>.Error.actorSystemUnavailable }
                let stream: CodableAsyncStream<Element>
//                if actorSystem.isServer {
                    stream = try CodableAsyncStream<Element>.resolve(id: id, using: actorSystem)
//                } else {
//                    stream = CodableAsyncStream<Element>(actorSystem: actorSystem)
//                }
                semaphore?.signal()
                await withTaskCancellationHandler {
                    do {
                        while let element = try await stream.next() {
                            continuation.yield(element)
                        }
                    } catch {
//                         continuation.finish(throwing: error)
                    }
                    continuation.finish()
                } onCancel: {
//                    Task {
//                        await actorSystem.releaseCodableAsyncStream(id)
//                    }
                }
            }
            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }

    public func encode(to encoder: Encoder) throws where Element: Sendable {
        @Dependency(\.actorSystem) var actorSystem
        guard let actorSystem else { throw CodableAsyncStream<Element>.Error.actorSystemUnavailable }
        let cas = CodableAsyncStream<Element>(actorSystem: actorSystem)
        cas.store(stream: self)
        var container = encoder.singleValueContainer()
        try container.encode(cas.id)
    }
}

public extension DependencyValues {
    var casSemaphore: AsyncSemaphore? {
        get { self[AsyncSemaphore.self] }
        set { self[AsyncSemaphore.self] = newValue }
    }
}

extension AsyncSemaphore: @retroactive DependencyKey {
    public static var liveValue: AsyncSemaphore? { nil }
    public static var testValue: AsyncSemaphore? { nil }
}

// this is a funny hack to make it possible to decode AsyncStream<any Codable> asynchronously
protocol _IsAsyncStreamOfCodable {}
extension AsyncStream: _IsAsyncStreamOfCodable where Element: Codable {}
extension AsyncStream: Sendable where Element: Sendable {}
