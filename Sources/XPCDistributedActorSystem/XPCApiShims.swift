import Foundation
import XPC

/// Minimal shims to allow compiling against the new XPCSession based APIs on platforms
/// where they may not yet be available. These definitions are *not* full implementations
/// of the real APIs.

public final class XPCSession {
    public enum ConnectionType {
        case remoteMachService(serviceName: String, isPrivilegedHelperTool: Bool)
        case remoteService(bundleID: String)
        case remoteServiceFromEndpoint(xpc_endpoint_t)
    }

    public var errorHandler: ((XPCSession, XPCError) -> Void)?

    public init(type: ConnectionType, codeSigningRequirement _: String? = nil) throws {
        // Placeholder initializer for compilation on non-macOS platforms.
    }

    public func activate() async throws {
        // Placeholder implementation
    }

    public func cancel() async throws {
        // Placeholder implementation
    }

    public func sendMessage<Request: Codable>(name _: String, request _: Request) async throws -> InvocationResponse<Data> {
        // Placeholder implementation
        throw XPCError(.connectionNotReady)
    }

    public func setMessageHandler<Request: Codable>(name _: String, handler _: @escaping (XPCSession, Request) async throws -> InvocationResponse<Data>) {
        // Placeholder implementation
    }
}

public final class XPCListener {
    public enum ListenerType {
        case service
        case machService(name: String)
        case anonymous
    }

    public var endpoint: xpc_endpoint_t {
        // Placeholder endpoint
        return xpc_endpoint_create(nil)
    }

    public var incomingSessionHandler: ((XPCSession) -> Void)?

    public init(type _: ListenerType, codeSigningRequirement _: String? = nil, incomingSessionHandler: @escaping (XPCSession) -> Void) throws {
        self.incomingSessionHandler = incomingSessionHandler
        // Placeholder initializer
    }

    public func activate() {
        // Placeholder implementation
    }
}
