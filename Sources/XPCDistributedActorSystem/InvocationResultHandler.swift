import Distributed
import Foundation

final class InvocationResultHandler: DistributedTargetInvocationResultHandler {
    typealias SerializationRequirement = any Codable
    private(set) var response: InvocationResponse<Data>?

    func onReturn<V: Codable>(value: V) async throws {
        let data = try JSONEncoder().encode(value)
        response = InvocationResponse(value: data)
    }

    func onReturnVoid() async throws {
        response = InvocationResponse<Never>()
    }

    func onThrow<Err>(error: Err) async throws where Err: Error {
        response = InvocationResponse(error: error)
    }
}
