import Dependencies
import Distributed
import Foundation

public struct GenericInvocationDecoder: DistributedTargetInvocationDecoder {
    static let decoder = JSONDecoder()

    enum Error: Swift.Error {
        case notEnoughArguments
    }

    public typealias SerializationRequirement = any Codable

    private let request: InvocationRequest
    private let system: XPCDistributedActorSystem
    private var argumentsIterator: Array<Data>.Iterator

    init(system: XPCDistributedActorSystem, request: InvocationRequest) {
        argumentsIterator = request.arguments.makeIterator()
        self.request = request
        self.system = system
        Self.decoder.userInfo[.actorSystemKey] = system
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard let data = argumentsIterator.next() else {
            throw Error.notEnoughArguments
        }
        return try withDependencies {
            $0.actorSystem = system
        } operation: {
            try Self.decoder.decode(Argument.self, from: data)
        }
    }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        request.genericSubstitutions.compactMap { _typeByName($0) }
    }

    public mutating func decodeErrorType() throws -> (Any.Type)? {
        guard let errorTypeMangled = request.errorType else { return nil }
        return _typeByName(errorTypeMangled)
    }

    public mutating func decodeReturnType() throws -> (Any.Type)? {
        guard let returnTypeMangled = request.returnType else { return nil }
        return _typeByName(returnTypeMangled)
    }
}
