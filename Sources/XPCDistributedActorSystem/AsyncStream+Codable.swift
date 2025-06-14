import Dependencies
import Distributed
import Foundation
import Semaphore

distributed actor CodableAsyncStream<Element> where Element: Codable & Sendable {
    typealias ActorSystem = XPCDistributedActorSystem

    private var iterator: AsyncStream<Element>.AsyncIterator?

    enum Error: Swift.Error {
        case actorSystemUnavailable, exhausted
    }

    init(stream: AsyncStream<Element>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        iterator = stream.makeAsyncIterator()
        @Dependency(\.dasAsyncStreamCodableSemaphore) var semaphore
        semaphore.signal()
    }

    distributed func next() async throws -> Element? {
        do {
            /// the Distributed framework does not guarantee typesafety omfg lmao so we have to double check
            guard self is Self else { throw Error.actorSystemUnavailable }
            return try await whenLocal { local in
                guard var iterator = local.iterator else { throw Error.exhausted }
                guard let next = await iterator.next(isolation: local.asLocalActor) else { throw Error.exhausted }
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
                do {
                    while let element = try await stream.next() {
                        continuation.yield(element)
                        try Task.checkCancellation()
                    }
                } catch {
                    print("ERROR IN ASYNC STREAM \(id): \(error)")
                    // continuation.finish(throwing: error)
                }
                continuation.finish()
            }
            @Dependency(\.distributedActorSystem) var das
            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }

    public func encode(to encoder: Encoder) throws where Element: Sendable {
        @Dependency(\.distributedActorSystem) var das
        guard let das else { throw CodableAsyncStream<Element>.Error.actorSystemUnavailable }
        let cas = CodableAsyncStream<Element>(stream: self, actorSystem: das)
        var container = encoder.singleValueContainer()
        try container.encode(cas.id)
    }
}

// this is a funny hack to make it possible to decode AsyncStream<any Codable> asynchronously
protocol _IsAsyncStreamOfCodable {}
extension AsyncStream: _IsAsyncStreamOfCodable where Element: Codable {}
extension AsyncStream: Sendable where Element: Sendable {}
