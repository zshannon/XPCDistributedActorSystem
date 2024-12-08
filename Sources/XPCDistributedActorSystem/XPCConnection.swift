@preconcurrency import XPC

// TODO: Implement code signature requirement verification (xpc_connection_set_peer_code_signing_requirement)
// TODO: Implement automatic reconnect

actor XPCConnection
{
    enum State {
        case created
        case active
        case invalid
        case interrupted
    }
    
    enum Error: Swift.Error {
        case failedToCreateReply
        case connectionNotReady
    }
    
    private let connection: xpc_connection_t
    private let actorSystem: XPCDistributedActorSystem
    private var state: State = .created
    
    init(incomingConnection connection: sending xpc_connection_t, actorSystem: XPCDistributedActorSystem)
    {
        self.init(connection: connection, actorSystem: actorSystem)
    }
    
    init(daemonServiceName: String, actorSystem: XPCDistributedActorSystem)
    {
        let connection = xpc_connection_create_mach_service(daemonServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        self.init(connection: connection, actorSystem: actorSystem)
    }
    
    init(serviceName: String, actorSystem: XPCDistributedActorSystem)
    {
        let connection = xpc_connection_create(serviceName, nil)
        self.init(connection: connection, actorSystem: actorSystem)
    }
    
    private init(connection: sending xpc_connection_t, actorSystem: XPCDistributedActorSystem)
    {
        self.connection = connection
        self.actorSystem = actorSystem
        
        xpc_connection_set_event_handler(connection, handleEvent)
        xpc_connection_activate(connection)
        
        Task {
            await setState(.active)
        }
    }
    
    private func setState(_ state: State)
    {
        self.state = state
    }

    public func close()
    {
        xpc_connection_cancel(connection)
    }
    
    nonisolated func handleEvent(_ event: xpc_object_t)
    {
        Task {
            if event === XPC_ERROR_CONNECTION_INVALID {
                await self.setState(.invalid)
                return
            } else if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                await self.setState(.interrupted)
                return
            }

            actorSystem.handleIncomingInvocation(connection: self, message: XPCMessageWithObject(raw: event))
        }
    }

    deinit
    {
        xpc_connection_cancel(connection)
    }
    
    func send<ObjectToSend, ObjectToReceive>(_ objectToSend: ObjectToSend, expect: ObjectToReceive.Type) async throws -> sending ObjectToReceive where ObjectToSend: Encodable, ObjectToReceive: Decodable
    {
        guard state == .active else { throw Error.connectionNotReady }
        
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
        guard state == .active else { throw Error.connectionNotReady }

        xpc_connection_send_message(connection, messageToSend.raw)
    }
    
    func reply(to request: XPCMessageWithObject) throws
    {
        guard state == .active else { throw Error.connectionNotReady }

        guard let message = xpc_dictionary_create_reply(request.raw) else { throw Error.failedToCreateReply }
        xpc_connection_send_message(connection, message)
    }
}
