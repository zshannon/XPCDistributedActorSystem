import Dependencies
import Distributed
import Foundation
import Semaphore

// Wrapper for Swift.Error to make it Codable and Sendable
struct CodableError: Codable, Sendable, Error {
    let description: String
    let type: String

    init(_ error: Error) {
        description = String(describing: error)
        type = String(describing: Swift.type(of: error))
    }

    var localizedDescription: String {
        description
    }
}

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
                guard let next = await iterator.next(isolation: local.asLocalActor) else {
                    throw Error.exhausted
                }
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

distributed actor CodableAsyncThrowingStream<Element, Failure>
    where Element: Codable & Sendable, Failure: Error
{
    typealias ActorSystem = XPCDistributedActorSystem

    private var iterator: AsyncThrowingStream<Element, Failure>.AsyncIterator?

    enum Error: Swift.Error {
        case actorSystemUnavailable, exhausted
    }

    init(stream: AsyncThrowingStream<Element, Failure>, actorSystem: ActorSystem) {
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
                do {
                    guard let next = try await iterator.next(isolation: local.asLocalActor) else {
                        throw Error.exhausted
                    }
                    return next
                } catch {
                    // Convert the original error to CodableError for transmission
                    throw CodableError(error)
                }
            }
        } catch {
            if case CodableAsyncThrowingStream.Error.exhausted = error {
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
                guard let das else {
                    throw CodableAsyncStream<Element>.Error.actorSystemUnavailable
                }
                let stream = try CodableAsyncStream<Element>.resolve(id: id, using: das)
                semaphore.signal()
                do {
                    while let element = try await stream.next() {
                        continuation.yield(element)
                        try Task.checkCancellation()
                    }
                } catch {
//                    print("ERROR IN ASYNC STREAM \(id): \(error)")
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

extension AsyncThrowingStream: Codable where Element: Codable, Failure == Error {
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
                guard let das else {
                    throw CodableAsyncThrowingStream<Element, Error>.Error.actorSystemUnavailable
                }
                let stream = try CodableAsyncThrowingStream<Element, Error>.resolve(
                    id: id, using: das,
                )
                semaphore.signal()
                do {
                    while let element = try await stream.next() {
                        continuation.yield(element)
                        try Task.checkCancellation()
                    }
                } catch {
                    continuation.finish(throwing: error)
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
        guard let das else {
            throw CodableAsyncThrowingStream<Element, Error>.Error.actorSystemUnavailable
        }
        let cas = CodableAsyncThrowingStream<Element, Error>(stream: self, actorSystem: das)
        var container = encoder.singleValueContainer()
        try container.encode(cas.id)
    }
}

// this is a funny hack to make it possible to decode AsyncStream<any Codable> asynchronously
protocol _IsAsyncStreamOfCodable {}
extension AsyncStream: _IsAsyncStreamOfCodable where Element: Codable {}
extension AsyncStream: Sendable where Element: Sendable {}

protocol _IsAsyncThrowingStreamOfCodable {}
extension AsyncThrowingStream: _IsAsyncThrowingStreamOfCodable where Element: Codable {}
extension AsyncThrowingStream: Sendable where Element: Sendable, Failure: Sendable {}
