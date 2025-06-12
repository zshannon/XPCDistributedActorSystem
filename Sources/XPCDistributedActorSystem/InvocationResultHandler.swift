import Dependencies
import Distributed
import Foundation

public final class InvocationResultHandler: DistributedTargetInvocationResultHandler, @unchecked Sendable {
    public typealias SerializationRequirement = any Codable
    private(set) var response: InvocationResponse<Data>?
    private(set) var responseType: Any.Type?

    private let system: XPCDistributedActorServer
    init(system: XPCDistributedActorServer) {
        self.system = system
    }

    public func onReturn(value: some Codable) async throws {
        responseType = type(of: value)
        let data = try withDependencies {
            $0.actorSystem = system
        } operation: {
            try JSONEncoder().encode(value)
        }
        response = InvocationResponse(value: data)
    }

    public func onReturnVoid() async throws {
        response = InvocationResponse<Data>(error: nil, value: nil)
    }

    public func onThrow(error: some Error) async throws {
        response = InvocationResponse<Data>(error: String(describing: error), value: nil)
    }
}
