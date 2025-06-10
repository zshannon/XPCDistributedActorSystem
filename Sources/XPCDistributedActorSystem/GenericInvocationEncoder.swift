import Distributed
import Foundation

public struct GenericInvocationEncoder: DistributedTargetInvocationEncoder, Sendable
{
    static let encoder = JSONEncoder()

    enum Error: Swift.Error {
        case failedToFindMangedName
    }

    public typealias SerializationRequirement = any Codable

    var generics: [String] = .init()
    var arguments: [Data] = .init()
    var returnType: String? = nil
    var errorType: String? = nil

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws
    {
        arguments.append(try Self.encoder.encode(argument.value))
    }

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws
    {
        guard let mangledName = _mangledTypeName(type) else { throw Error.failedToFindMangedName }
        generics.append(mangledName)
    }

    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws
    {
        self.returnType = _mangledTypeName(type)
    }

    public mutating func recordErrorType<E: Swift.Error>(_ type: E.Type) throws
    {
        self.errorType = _mangledTypeName(type)
    }

    public mutating func doneRecording() throws {}
}
