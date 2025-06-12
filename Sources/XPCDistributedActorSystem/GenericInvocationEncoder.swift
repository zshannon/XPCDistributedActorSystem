import Dependencies
import Distributed
import Foundation

public struct GenericInvocationEncoder: DistributedTargetInvocationEncoder, Sendable {
    static let encoder = JSONEncoder()

    enum Error: Swift.Error {
        case failedToFindMangedName
    }

    public typealias SerializationRequirement = any Codable

    var generics: [String] = .init()
    var arguments: [Data] = .init()
    var returnType: String? = nil
    var errorType: String? = nil

    private let system: XPCDistributedActorSystem

    init(system: XPCDistributedActorSystem) {
        self.system = system
    }

    public mutating func recordArgument(_ argument: RemoteCallArgument<some Codable>) throws {
        let data = try withDependencies {
            $0.actorSystem = system
        } operation: {
            try Self.encoder.encode(argument.value)
        }
        arguments.append(data)
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
