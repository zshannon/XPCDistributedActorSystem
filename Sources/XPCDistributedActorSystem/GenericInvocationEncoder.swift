import Dependencies
import Distributed
import Foundation
import Semaphore

public struct GenericInvocationEncoder: DistributedTargetInvocationEncoder, Sendable {
    enum Error: Swift.Error {
        case failedToFindMangedName
    }

    public typealias SerializationRequirement = any Codable

    var generics: [String] = .init()
    var arguments: [Data] = .init()
    var returnType: String? = nil
    var errorType: String? = nil

    private let actorSystem: XPCDistributedActorSystem
    private let encoder = JSONEncoder()
    private let id: UUID = .init()

    init(actorSystem: XPCDistributedActorSystem) {
        self.actorSystem = actorSystem
    }

    private var asyncStreamEncodingTasks: [Task<Void, Swift.Error>] = []
    public func waitForAsyncStreamEncoding() async {
        guard !asyncStreamEncodingTasks.isEmpty else { return }
        await withTaskGroup { group in
            for task in asyncStreamEncodingTasks {
                group.addTask {
                    try? await task.value
                }
            }
            await group.waitForAll()
        }
    }
    
    public mutating func recordArgument(_ argument: RemoteCallArgument<some Codable>) throws {
        let semaphore: AsyncSemaphore = .init(value: 0)
        if type(of: argument.value) is _IsAsyncStreamOfCodable.Type {
            asyncStreamEncodingTasks.append(Task { [semaphore] in
                try await semaphore.waitUnlessCancelled()
            })
        }
        try withDependencies {
            $0.distributedActorSystem = actorSystem
            $0.dasAsyncStreamCodableSemaphore = semaphore
        } operation: {
            try arguments.append(encoder.encode(argument.value))
        }
    }

    public mutating func recordGenericSubstitution(_ type: (some Any).Type) throws {
        guard let mangledName = _mangledTypeName(type) else { throw Error.failedToFindMangedName }
        generics.append(mangledName)
    }

    public mutating func recordReturnType(_ type: (some Codable).Type) throws {
        returnType = _mangledTypeName(type)
    }

    public mutating func recordErrorType(_ type: (some Swift.Error).Type) throws {
        errorType = _mangledTypeName(type)
    }

    public mutating func doneRecording() throws {}
}
