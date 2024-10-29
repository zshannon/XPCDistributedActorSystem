import Foundation
@preconcurrency import XPC

// TODO: Code signature requirement verification
// TODO: Test and implement automatic reconnect

actor XPCConnection
{
    enum Mode: Equatable, Sendable {
        case anonymousListener
        case daemonListener(service: String)
        case client(service: String)
    }

    enum Error: Swift.Error {
        case failedToCreateReply
        case connectionMissing
    }
    
    typealias MessageReceivedHandler = @Sendable (isolated XPCConnection, XPCMessageWithObject) -> Void

    static let main = XPCConnection()

    private var connection: xpc_connection_t?
    private var handler: MessageReceivedHandler?
    private let isMainListener: Bool
    
    init(mode: Mode)
    {
        self.isMainListener = false
        
        switch mode {
        case .anonymousListener:
            self.connection = xpc_connection_create(nil, nil)
        case .daemonListener(let service):
            self.connection = xpc_connection_create_mach_service(service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        case .client(let service):
            self.connection = xpc_connection_create(service, nil)
        }
    }
    
    /// Only to be used to create the `mainListener` once
    private init()
    {
        self.isMainListener = true
    }
    
    nonisolated func setHandler(_ handler: sending @escaping MessageReceivedHandler)
    {
        Task {
            await registerHandlerAndSetOnConnection(handler)
        }
    }
    
    private func registerHandlerAndSetOnConnection(_ handler: sending @escaping MessageReceivedHandler)
    {
        self.handler = handler
        self.setHandlerOnConnectionAndActivate()
    }

    private func setHandlerOnConnectionAndActivate()
    {
        guard let connection else { return }
        xpc_connection_set_event_handler(connection, handleMessage)
        xpc_connection_activate(connection)
    }
    
    nonisolated func handleMessage(_ message: xpc_object_t)
    {
        Task { @Sendable in
            guard let handler = await handler else { return }
            await handler(self, XPCMessageWithObject(raw: message))
        }
    }
        
    nonisolated func startMainAndBlock() -> Never
    {
        guard self.isMainListener else {
            fatalError("Tried to start the XPC springboard on a XPCConnection that isn't configured as `.mainListener`.")
        }
        
        xpc_main { connection in
            Task { @Sendable in
                await XPCConnection.main.setConnection(connection)
            }
        }
    }

    func setConnection(_ connection: sending xpc_connection_t)
    {
        if let previousConnection = self.connection {
            xpc_connection_cancel(previousConnection)
        }
        
        self.connection = connection
        self.setHandlerOnConnectionAndActivate()
    }

    deinit
    {
        guard let connection else { return }
        xpc_connection_cancel(connection)
    }
    
    func send<ObjectToSend, ObjectToReceive>(_ objectToSend: ObjectToSend, expect: ObjectToReceive.Type) async throws -> sending ObjectToReceive where ObjectToSend: Encodable, ObjectToReceive: Decodable
    {
        guard let connection else {
            throw Error.connectionMissing
        }

        let messageToSend = try XPCMessageWithObject(from: objectToSend)
        
        let receivedMessage: xpc_object_t = try await withCheckedThrowingContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, messageToSend.raw, nil) { message in
                continuation.resume(returning: message)
            }
        }
        
        let receivedMessageWithObject = XPCMessageWithObject(raw: receivedMessage)
        let extractedObject = try receivedMessageWithObject.extract(ObjectToReceive.self)
        return extractedObject
    }
    
    func reply(with messageToSend: sending XPCMessageWithObject) throws
    {
        guard let connection else {
            throw Error.connectionMissing
        }

        xpc_connection_send_message(connection, messageToSend.raw)
    }
    
    func reply(to request: XPCMessageWithObject) throws
    {
        guard let connection else {
            throw Error.connectionMissing
        }

        guard let message = xpc_dictionary_create_reply(request.raw) else { throw Error.failedToCreateReply }
        xpc_connection_send_message(connection, message)
    }
}

